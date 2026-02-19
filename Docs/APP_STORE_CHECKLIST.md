# App Store Checklist

Use this checklist before submitting OnDue.

## Privacy and Policy

- Host a public privacy policy and update `App/AppPrivacyConfiguration.swift` with the final URL.
- Add the same privacy policy URL in App Store Connect.
- Add the same privacy policy URL in Google Cloud OAuth consent screen.
- Verify in-app Privacy Policy links open successfully from Settings and Connect screens.

## Required Artifacts

- Ensure `PrivacyInfo.xcprivacy` exists and is included in the OnDue target resources.
- Verify `PrivacyInfo.xcprivacy` contains required reason API declarations for app usage.
- Confirm App Store privacy disclosures match actual app behavior.

## Gmail and Account Controls

- Verify Gmail scope is read-only (`gmail.readonly`) in production config.
- Verify account disconnect signs out and cancels scheduled background tasks.
- Verify "Delete all account data" removes synced local data and signs out user.
- Verify user can control background sync and long scan behavior through Sync Policy.

## QA Scenarios

- Fresh install -> connect Gmail -> sync -> verify expected data in digest.
- Run 12-month backfill and confirm chunked progress appears.
- Simulate API limit and confirm graceful stop + resume messaging.
- Trigger background sync disabled/enabled states and verify behavior matches policy toggles.
- Open privacy link from Settings and Connect while connected and disconnected.

## Submission Notes

- Document known limitations in release notes (for example: long scans may pause on API limits).
- Keep support contact and privacy policy URL consistent across app, website, and App Store metadata.
