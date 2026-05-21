# rivian-reddit-monitor

Daily summary of [r/Rivian](https://www.reddit.com/r/Rivian/) discussions —
with a dedicated section for voice-assistant bug reports — delivered to
Slack. Designed to run on [cronicle](https://github.com/jshiv/cronicle)
end-to-end with the workflow defined in [`cronicle.hcl`](./cronicle.hcl).

## Pipeline

```
install_deps  →  scrape  →  summarize  →  deliver
   pip            python      Claude        curl → Slack
```

| step | what it does |
|---|---|
| `install_deps` | `pip install --user -r requirements.txt` (just `requests` today). Idempotent. |
| `scrape` | `scripts/scrape_reddit.py` pulls the last 24h of `/r/Rivian/new.json` into `${scratch}/posts.json`. Anonymous fetch, no Reddit API key required. |
| `summarize` | Claude Haiku reads the posts and writes a markdown report to `${scratch}/report.md` — sections for headline, top discussions, **voice assistant**, sentiment. |
| `deliver` | `curl` posts the report to the configured Slack incoming webhook. |

## Required secrets

Set both in the cronicle UI (Project → Secrets) before the first run:

| name | source |
|---|---|
| `ANTHROPIC_API_KEY` | https://console.anthropic.com → API Keys |
| `SLACK_WEBHOOK_URL` | Slack app → Features → Incoming Webhooks → Add to channel |

## Runtime expectations of the cronicled container

`install_deps` runs `scripts/setup.sh` which is **fully self-contained** —
it apk/apt-gets `python3 py3-pip jq curl` if the container doesn't
already have them, then pip-installs `requirements.txt`. So the only
real requirement is that the cronicled container is alpine or
debian-based (the stock alpine cronicled image qualifies).

Re-runs of `install_deps` are ~0s once everything's cached.

## Deploying via cronicle UI

The intended path is the "Init from repo" wizard tab:

1. cronicle UI → **New project**
2. **Init from repo**, paste the repo URL, click **Fetch**
3. Set the two secrets above on the project's Secrets page
4. Wait for `0 9 * * *` America/Los_Angeles — or hit **Run now** to dry-run

The repo block in [`cronicle.hcl`](./cronicle.hcl) means cronicled
re-clones this repo before every task run, so any change to
`scripts/scrape_reddit.py` shows up in the next scheduled run with no
redeploy.

## Local dev

```bash
# scrape directly to stdout-ish
python3 scripts/scrape_reddit.py /tmp/posts.json
cat /tmp/posts.json | jq '.[:3]'

# parse + dry-run the HCL
cronicle exec --path ./cronicle.hcl --schedule rivian_daily --task scrape
```

`cronicle exec` skips the cron and runs one task — handy for poking
the pipeline without waiting for 09:00.
