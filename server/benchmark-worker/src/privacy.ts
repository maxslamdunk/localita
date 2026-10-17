// The app's privacy policy, served at `GET /privacy`. The App Store listing
// and the app's Settings link here. It has to stay true of the app and of
// this Worker: a change to what either collects changes this page in the same
// commit, with a new effective date. The app's `PrivacyInfo.xcprivacy` and
// the App Store privacy label say the same things in Apple's terms.

// The app's name, as its users see it.
export const APP_NAME = "TurboFieldfare";

export const PRIVACY_EFFECTIVE = "16 October 2026";

export const PRIVACY_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${APP_NAME} Privacy Policy</title>
<style>
  :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #fff; --link: #0066cc; }
  @media (prefers-color-scheme: dark) {
    :root { --fg: #f5f5f7; --muted: #a1a1a6; --bg: #000; --link: #2997ff; }
  }
  body { margin: 0; background: var(--bg); color: var(--fg);
         font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
  main { max-width: 680px; margin: 0 auto; padding: 32px 16px 64px; }
  h1 { font-size: 28px; line-height: 1.2; margin: 0 0 4px; }
  h2 { font-size: 20px; margin: 32px 0 8px; }
  .muted { color: var(--muted); }
  a { color: var(--link); }
  li { margin: 4px 0; }
</style>
</head>
<body>
<main>
<h1>${APP_NAME} Privacy Policy</h1>
<p class="muted">Effective ${PRIVACY_EFFECTIVE}</p>

<p>${APP_NAME} runs an AI model on your iPhone. It is built so that your
conversations never leave the phone. This page says what the app keeps, the two
cases in which anything leaves the phone, and who to contact.</p>

<h2>What stays on your iPhone</h2>
<ul>
  <li>Your chats, the images you attach to them, and your settings. The model runs
  on the phone, and nothing you type or attach is sent anywhere.</li>
  <li>Benchmark runs and their log files, until you delete them or the app.</li>
</ul>
<p>The app has no accounts, ads, analytics or tracking, and contains no
third-party code that collects data. Like other app data, your chats and settings
can be part of your iPhone's iCloud or computer backup, under Apple's terms; the
downloaded model is excluded from backups.</p>

<h2>What leaves your iPhone</h2>

<p><strong>1. Downloading a model.</strong> The app downloads models and the
image-support pack from Hugging Face (huggingface.co), and asks Hugging Face for a
model's details when you add one. As with any download, Hugging Face's servers see
your IP address and which files are requested. The requests carry only what any
iPhone download carries, such as the app and iOS versions, and nothing about you.
See
<a href="https://huggingface.co/privacy">Hugging Face's privacy policy</a>.</p>

<p><strong>2. Sending a benchmark result, only if you choose to.</strong> Nothing
is sent unless you open a finished benchmark run, choose
<em>Send to the Project</em>, and tap <em>Send</em>. That screen shows the report
in full before it goes. A report contains:</p>
<ul>
  <li>the iPhone's model identifier (such as “iPhone18,3”) and its memory size;</li>
  <li>the iOS and app versions;</li>
  <li>when the run started and finished, and, if it failed, the error message, with
  any file locations removed;</li>
  <li>battery level and charging state, Low Power Mode, and the phone's thermal
  state when each benchmark prompt ran;</li>
  <li>the model's name and a fingerprint of its files, and the benchmark's
  settings;</li>
  <li>speed, timing and memory figures for each benchmark prompt, and a
  fingerprint of the text the model generated from the benchmark's fixed
  prompts;</li>
  <li>a random report ID, made for that run.</li>
</ul>
<p>A report never contains your chats, your name, an account, or an identifier
of your iPhone.</p>
<p>The report goes to a server the developer runs on Cloudflare, which checks it
and stores it in a database. The developer is responsible for this data, and
sends and keeps it on the basis of your consent, given by tapping <em>Send</em>.
The server uses your IP address only to limit how
many reports one network can send per minute; it does not store or log it.
Cloudflare processes the request as the hosting provider (see
<a href="https://www.cloudflare.com/privacypolicy/">Cloudflare's privacy policy</a>).
Accepted reports are published in the project's public
source repository, so that anyone can compare how iPhones run the model.</p>

<p><strong>Apple's own reports.</strong> If you allow it in your iPhone's settings
(Privacy &amp; Security, Analytics &amp; Improvements, Share With App Developers),
Apple may give the developer crash reports and usage statistics for the app. If you
test the app through TestFlight, Apple shares with the developer the details
TestFlight describes when you join, which can include your email address, and any
feedback you send. The app adds nothing to these.</p>

<h2>Keeping and removing results</h2>
<p>Results are kept for as long as the project publishes benchmark results.
Because a report holds nothing that identifies you, the developer cannot tell
which results are yours. After you send a run, its result screen shows its report
ID. Email that ID to the address below and the result will be deleted from the database and left out of every later
publication. Copies already published remain
in the repository's history.</p>
<p>Deleting chats or benchmark runs in the app, or deleting the app, removes them
from your iPhone.</p>

<h2>Your rights</h2>
<p>Sending a result is your choice, and you can have it removed as described above.
For any question about your data, contact the developer. If you are in the EU or the
UK, you can also complain to your data protection authority.</p>

<h2>Changes</h2>
<p>Changes to this policy are published at this address with a new effective date.</p>

<h2>Contact</h2>
<p>Maxim Voronin, developer of ${APP_NAME}:
<a href="mailto:maximvoronin8@gmail.com">maximvoronin8@gmail.com</a></p>
</main>
</body>
</html>
`;
