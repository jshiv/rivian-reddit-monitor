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
//   - python3 + pip3 (the `install_deps` task `pip install --user`s
//     into ~/.local/lib/python*/site-packages; on alpine images you
//     may need py3-pip baked in)
//   - curl + jq (for the Slack delivery step — both standard on the
//     stock cronicled image)
//
// To init a fresh cronicle project from this repo:
//   1. cronicle UI → New project → Init from repo
//   2. paste the repo URL
//   3. populate ANTHROPIC_API_KEY + SLACK_WEBHOOK_URL on the
//      Secrets page

schedule "rivian_daily" {
  // 09:00 local. Adjust the timezone to your team's morning if you're
  // not on the West Coast.
  cron     = "0 9 * * *"
  timezone = "America/Los_Angeles"

  // Schedule-level repo block: cronicled clones this into the task
  // workspace before each task runs (idempotent — subsequent runs
  // do `git fetch` + checkout the latest commit on the branch).
  // Source code (scripts/, requirements.txt) stays in sync with the
  // repo automatically; the cronicle.hcl itself syncs only via
  // cronicle-infra's repo-init flow or the manual "Sync now" button.
  repo {
    url    = "https://github.com/jshiv/rivian-reddit-monitor.git"
    branch = "main"
  }

  // 1. Install Python deps. `pip install --user` lands in HOME so
  // subsequent task containers in the same run share the install
  // (they share /work, which is where the scratch dir lives too).
  // Idempotent — pip is a no-op when everything's already on disk.
  task "install_deps" {
    command = ["sh", "-c", "pip3 install --user --no-warn-script-location -r requirements.txt"]
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
