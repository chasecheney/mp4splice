# App Store Submission Checklist — MP4Splice

## What's already done in the repo
- App Sandbox enabled, with only `user-selected.read-write` (App Store–compliant).
- Hardened runtime on.
- `PrivacyInfo.xcprivacy` (no tracking, no data collected, no required-reason APIs) bundled.
- `ITSAppUsesNonExemptEncryption = NO` (skips the export-compliance prompt).
- App category set to Video; copyright string set.
- App icon (all macOS sizes incl. 1024) in the asset catalog.
- `PRIVACY.md` to host as your privacy policy URL.

## One-time account setup
1. Enroll in the **Apple Developer Program** ($99/yr).
2. In **App Store Connect**, create a new macOS app record and reserve the name **MP4Splice**.
3. Note your **Team ID** and put it in `ExportOptions-AppStore.plist` (replace `YOUR_TEAM_ID`).
4. In Xcode → Signing & Capabilities, set the team and let it manage **Apple Distribution** signing.

## Before each submission
- Bump `MARKETING_VERSION` (currently 1.0.1) and `CURRENT_PROJECT_VERSION` (build number) if resubmitting.
- Test on a real Mac: empty inputs, unsupported files, cancel mid-encode, large files, join of
  mismatched resolutions, all split modes. Apple rejects on reproducible crashes.

## Build, archive, and upload (command line)
```sh
cd ~/claude/mp4joiner

# 1. Archive
xcodebuild -project MP4Splice/MP4Splice.xcodeproj \
  -scheme MP4Splice -configuration Release \
  -archivePath build/MP4Splice.xcarchive archive

# 2. Export + upload to App Store Connect
xcodebuild -exportArchive \
  -archivePath build/MP4Splice.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore.plist \
  -exportPath build/export
```
Or simpler: open the archive in **Xcode → Organizer → Distribute App → App Store Connect**.

## In App Store Connect (per release)
- Upload at least one screenshot (1280×800 or 2560×1600 for macOS).
- Write description, keywords, support URL, and **privacy policy URL** (host `PRIVACY.md`).
- Fill the **App Privacy** section: "Data Not Collected".
- Set age rating (4+), pricing (Free).
- Submit for review.

## Notes
- The free direct-download path (notarized DMG) stays available and avoids review entirely.
- App Store gives discoverability and automatic updates.
