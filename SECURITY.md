# Security

KeystrokeCounter is a small, independently maintained project — not a company with a dedicated security team — but privacy and security reports are genuinely welcome, and taken seriously. Given that this app requests Accessibility permission to observe keyboard and mouse events, issues affecting how that data is captured, processed, or stored are considered high priority, even if they'd normally seem minor in a different kind of app.

## Reporting a vulnerability

This repository does not currently have GitHub's private vulnerability reporting enabled, so there isn't yet a confidential channel for sensitive reports. Until that changes, please report an issue by [opening a GitHub issue](https://github.com/adamalnajjar/keystroke_counter/issues) with as much detail as you're comfortable sharing publicly, or by reaching out to the repository owner directly via their [GitHub profile](https://github.com/adamalnajjar).

If a report involves details you'd rather not post publicly (for example, a proof-of-concept that demonstrates data exposure beyond counts and app names), say so in a brief public issue and ask for a way to share details privately — please don't include sensitive specifics in the initial public report.

## Scope

Reports most relevant to this project involve:

- Any way the app could capture, store, or expose more than aggregate counts and app names — for example, anything that could reconstruct typed content, key sequences, or window/screen content
- Any way stored statistics could be accessed by another process or user without authorization
- Any unexpected network activity (the app should make no requests at all unless sync is enabled, and then only to the configured server)
- Weaknesses in the optional self-hosted sync server (`server/`)

This project has no user accounts or third-party dependencies, and its only server component is the optional self-hosted sync backend, so most traditional web/application vulnerability classes don't apply — but if you've found something wrong regardless of category, it's still worth reporting.
