# Clermont Air & Heat — HVAC Chatbot + Missed-Call Text-Back

Same architecture as the Lake America build, extended with Twilio for
missed-call text-back. Fully separate AWS resources — nothing here touches
the Lake America deployment.

## What's in this bundle

| File | Purpose |
|---|---|
| `hvac-lambda_function.py` | Backend — chat widget, dashboard, AND Twilio voice/SMS webhooks, all in one Lambda (routed by URL path) |
| `hvac-iam-trust-policy.json` / `hvac-iam-permissions-policy.json` | IAM role definition |
| `config-hvac.env.example` | Copy to `config-hvac.env`, fill in — includes Twilio fields, leave blank until you have an account |
| `deploy-hvac.ps1` / `destroy-hvac.ps1` | Provision / tear down the backend |
| `deploy-hvac-site.ps1` | Hosts the demo site + dashboard on S3 + CloudFront (free HTTPS subdomain) |
| `hvac-chat-widget.js` | Embeddable chat widget |
| `hvac-dashboard.html` | Staff-facing table of captured job requests, no Excel needed |
| `hvac-live-site.html` | Demo site with the widget wired in |
| `update-hvac-widget-endpoint.ps1` | Points both the widget and dashboard at your live API URL |

## Part 1 — get the chat widget working (no Twilio needed yet)

This is identical to the Lake America process:

```powershell
mkdir C:\Users\Administrator\Documents\hvac-chatbot
cd C:\Users\Administrator\Documents\hvac-chatbot
# download all the files above into this folder

Copy-Item config-hvac.env.example config-hvac.env
notepad config-hvac.env
# fill in ANTHROPIC_API_KEY and S3_BUCKET (globally unique name)
# leave TWILIO_* fields blank for now

.\deploy-hvac.ps1
# prints your live API endpoint

.\update-hvac-widget-endpoint.ps1 -Endpoint "https://your-api-id.execute-api.us-east-1.amazonaws.com/"

.\deploy-hvac-site.ps1
# prints your public demo site URL + dashboard URL
```

Test it: open the printed site URL, click the chat bubble, describe an AC
problem, give a name/phone/day preference. Check the dashboard URL —
you should see a new row with Urgency correctly tagged (emergency/routine).

At this point you have a fully working website chatbot, same as Lake
America — this alone is sellable. Everything below is the missed-call
add-on.

## Part 2 — adding missed-call text-back (requires a Twilio account)

### Step 1: Create a Twilio account and get a phone number

1. Go to [twilio.com/try-twilio](https://www.twilio.com/try-twilio) and sign up (free trial gives you credit to test with)
2. In the Twilio Console, go to **Phone Numbers → Buy a Number** — pick a local number (e.g., a 352 or 407 area code for Clermont/Orlando). Trial accounts can claim one number for free; paid accounts pay roughly $1-2/month per number
3. From the Console dashboard, copy your **Account SID** and **Auth Token** (click to reveal it)

### Step 2: Add those values to `config-hvac.env`

```
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=your_auth_token_here
TWILIO_PHONE_NUMBER=+13525551234
```

Then redeploy so the Lambda picks up these new environment variables:

```powershell
.\deploy-hvac.ps1
```

The output will print two URLs you need for the next step — they'll look like:

```
Voice webhook: https://your-api-id.execute-api.us-east-1.amazonaws.com/voice
SMS webhook:   https://your-api-id.execute-api.us-east-1.amazonaws.com/sms
```

### Step 3: Point the Twilio number at those webhooks

1. In the Twilio Console, go to **Phone Numbers → Manage → Active Numbers**, click your number
2. Under **Voice Configuration**: set "A call comes in" to **Webhook**, paste the `/voice` URL, method **HTTP POST**
3. Under **Messaging Configuration**: set "A message comes in" to **Webhook**, paste the `/sms` URL, method **HTTP POST**
4. Save

### Step 4: Test it directly (before touching any real business phone)

Just call your new Twilio number from your own cell phone. Since nothing
is forwarding to it yet, calling it directly simulates "the call already
went unanswered" — you should immediately hear a short message and get a
text within a few seconds. Reply to that text like a real customer
("my AC stopped working, I'm home now") and you should get an AI reply
back within a few seconds, the same conversation logic as the website
widget. Check the dashboard — a new row should appear once you've given
a name and enough detail.

### Step 5: Connect it to a real business phone (only once you have a real client)

This is the step that makes it "missed-call" text-back instead of "call
this number directly." The business's real number (their AT&T landline,
cell, whatever it already is) needs **conditional call forwarding** set up:
"if unanswered after N rings, forward to [the Twilio number]." This is a
setting on the business's own phone service — usually a code they dial on
their own phone, or a setting in their carrier's account portal — not
something Twilio or this code touches. Their main number never changes;
Twilio only receives a call when nobody picked up.

## Cost reality

Same near-zero-when-idle profile as Lake America for the AWS side. Twilio
adds: the phone number itself (~$1-2/month), plus per-message
(~$0.0079/SMS) and per-minute costs for any inbound voice minutes before
the call gets diverted to voicemail-replacement (typically just a few
seconds, since the TwiML response is immediate). At realistic small-HVAC
volume (a few missed calls a day), expect a few extra dollars a month on
top of the Anthropic API costs already covered in the Lake America README.

## Known simplification, worth knowing

The dashboard's `API_ENDPOINT` and the widget's `apiEndpoint` are both
plain text in client-side files — fine for a demo/pilot, and consistent
with how the Lake America build works. Before real production use with a
paying client, consider moving CORS to their real domain only (already
covered in the "before handing this to a real client" pattern from Lake
America) and evaluate whether the dashboard needs a login (currently:
anyone with the URL can view it — see the earlier conversation about
access control options if this needs to be locked down).
