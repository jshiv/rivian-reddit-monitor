// Daily Rivian Reddit monitor.
//
// Pipeline: scrape /r/Rivian (last 24h) → Claude summarises with a
// specific section on voice-assistant bug reports → Slack delivers
// the report. All four tasks live in this repo so the workflow
// versions cleanly alongside the code that produces it.
//
// Required secrets (set via the cronicle UI or `cronicle secret set`):
//
//   ANTHROPIC_API_KEY  - https://console.anthropic.com (for the
//                        `summarize` agent step)
//   SLACK_WEBHOOK_URL  - Slack app → Incoming Webhooks → channel of
//                        choice (for `deliver`)
//
// Runtime expectations of the cronicled container:
//
//   The `install_deps` task runs scripts/setup.sh which apk/apt-get
//   installs python3, pip3, jq, and curl when missing, then pip-installs
//   requirements.txt. Net effect: the only thing the container actually
//   needs is sh + a supported package manager (alpine or debian). The
//   stock cronicled alpine image qualifies.
//
// To init a fresh cronicle project from this repo:
//   1. cronicle UI → New project → Init from repo
//   2. paste the repo URL
//   3. populate ANTHROPIC_API_KEY + SLACK_WEBHOOK_URL on the
//      Secrets page

// Top-level repo block: this is the marker that tells cronicle-infra
// "this project is managed by a repo" (Mode A). cronicled inherits
// it as the per-schedule code source, and the UI shows the "Synced
// from" banner + a Sync-now button. Cronicle's runtime propagates
// the top-level repo down to every schedule so each task workdir
// is a fresh clone — same idempotent fetch+checkout pipeline as a
// schedule-level repo, just declared once at the top.
repo {
  url    = "https://github.com/jshiv/rivian-reddit-monitor.git"
  branch = "main"
}

schedule "rivian_daily" {
  // 09:00 local. Adjust the timezone to your team's morning if you're
  // not on the West Coast.
  cron     = "0 9 * * *"
  timezone = "America/Los_Angeles"

  // 1. Self-contained setup: scripts/setup.sh installs python3, pip3,
  // jq, and curl if the container's missing any, then pip-installs
  // requirements.txt. Idempotent — re-runs are ~0s.
  task "install_deps" {
    command = ["sh", "scripts/setup.sh"]
  }

  // 2. Scrape Reddit. Writes a slim JSON array of posts to the
  // schedule-scoped scratch dir so the agent step can read it without
  // a separate handoff.
  task "scrape" {
    depends = ["install_deps"]
    command = ["python3", "scripts/scrape_reddit.py", "${scratch}/posts.json"]
  }

  // 3. Summarize. Claude Haiku reads posts.json, follows the prompt's
  // section spec, writes the report to scratch. The voice-assistant
  // section is called out explicitly so the agent doesn't quietly
  // drop it on slow news days.
  task "summarize" {
    depends = ["scrape"]
    env     = ["ANTHROPIC_API_KEY=$secret.ANTHROPIC_API_KEY"]

    agent {
      model      = "claude-haiku-4-5"
      prompt     = <<-EOT
        Today is ${date}. Read ${scratch}/posts.json — it contains the
        last 24 hours of posts from r/Rivian (each entry has title,
        selftext, score, num_comments, author, permalink, created_utc).

        Write a concise daily report to ${scratch}/report.md with these
        sections:

        ## Headline
        One sentence on the most-discussed topic of the day.

        ## Top discussions
        Three bullets, each with the post title (linked via permalink)
        and one-sentence summary of why it's notable. Pick by a mix of
        score + comment count.

        ## Rivian voice assistant
        Surface every post mentioning the in-vehicle voice assistant
        (Alexa, "voice command", "VA", "Hey Rivian", etc.). Quote the
        user's complaint verbatim where it helps. Even if there are no
        voice-assistant posts today, INCLUDE this section with the
        line: "No voice-assistant posts in the last 24 hours."

        ## Sentiment
        One sentence on the overall mood: enthusiastic / mixed / negative.

        Keep the whole report under 400 words. Use text_editor to write
        the file. Reply: REPORT WRITTEN.
      EOT
      tools      = ["text_editor", "bash"]
      max_turns  = 10
      wallclock  = "3m"
      budget_usd = 0.20
      max_tokens = 2000
    }
  }

  // 4. Deliver to Slack. jq -Rs reads the markdown verbatim and emits
  // it as a JSON-escaped string so multi-line bodies stay intact in
  // the {"text": ...} envelope Slack expects.
  task "deliver" {
    depends = ["summarize"]
    env     = ["SLACK_WEBHOOK_URL=$secret.SLACK_WEBHOOK_URL"]
    command = ["sh", "-c", "curl -fsSL -X POST -H 'Content-Type: application/json' -d \"{\\\"text\\\": $(jq -Rs . < ${scratch}/report.md)}\" \"$SLACK_WEBHOOK_URL\""]
  }
}
