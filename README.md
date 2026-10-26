# Pavan Residency (Receipt Mailer) (Flutter)

Android app for **Pavan Residency Co-op Housing Society**.
It creates maintenance receipts in **Gujarati / Hindi / English** and emails them
through **your own SMTP** account (Gmail etc.; the settings are stored on the phone).
You can send one receipt at a time or many at once from a CSV file.

| | |
|---|---|
| **Owner** | [pravin-python](https://github.com/pravin-python) |
| **Repository** | https://github.com/pravin-python/pavan_residency |
| **App id** | `com.pavanresidency.pavan_residency` |
| **Current version** | `1.1.2+4` (see `version:` in `pubspec.yaml`; the app shows it at the bottom of **Settings**) |
| **Android** | 7.0+ (minSdk 24), target SDK 36 |
| **Built with** | Flutter 3.47 (stable), JDK 17, Android SDK 36 |

---

## Contents

1. [Features](#features)
2. [A–Z: new PC setup (one time)](#az-new-pc-setup-one-time)
3. [Project setup](#project-setup)
4. [Running the app on a phone](#running-the-app-on-a-phone)
5. [Building the release APK / AAB](#building-the-release-apk--aab)
6. [Release signing key (important)](#release-signing-key-important)
7. [Installing on a phone / Play Store](#installing-on-a-phone--play-store)
8. [Gmail SMTP setup](#gmail-smtp-setup)
9. [CSV format (Bulk)](#csv-format-bulk)
10. [Google Sheets (Bulk)](#google-sheets-bulk)
11. [Receipt number rules](#receipt-number-rules)
12. [Permissions](#permissions)
13. [Project structure](#project-structure)
14. [Tests](#tests)
15. [Troubleshooting](#troubleshooting)

---

## Features

- **Single**: fill the form (Block A/B/C, Payment Mode, Type, Other details), see a PDF preview, and send the email.
- **Bulk**: the recipients come from **Google Sheets (default)** or from a **CSV file**. With Google Sheets the app also writes `TRUE` / `FALSE` into an `email_sent` column of the sheet after each send (see [Google Sheets (Bulk)](#google-sheets-bulk)). Each row gets its own receipt (in that row's language, type and mode). **Send All Emails** sends every ready row **in parallel** (up to 4 SMTP connections at once, each logged in once and reused), shows a status for every row, and you can press **Stop** at any time.
  - Rows are sent one at a time until the first email is delivered. That checks the login, so a wrong password fails once instead of four times.
  - If the mail server allows fewer parallel connections, the extra connections hand their rows back and the rest are still sent.
  - Receipts that were already sent (for example after an interrupted run) are skipped. Long-press a row to send it again.
  - If the password is wrong or Gmail's daily limit is reached, Bulk stops by itself.
- **Universal receipt**: the payment section is the same for Cash, Cheque and Online. It always shows Mode, Bank, Cheque No. and Transaction No. (`-` if blank).
- **Settings** (saved on the device): SMTP host / port / SSL / username / app password, sender name, subject template, PDF attachment on/off, next receipt no., and a signature image (jpg/png, shrunk automatically).
- The receipt looks like the printed receipt book (red/pink). The amount is also written **in words** in all three languages (Indian lakh/crore system).
- The email body contains an HTML receipt, and a vector **PDF** is attached (A5 landscape with embedded Noto fonts).

---

## A–Z: new PC setup (one time)

> On this PC everything is already installed at the paths below. Follow these steps only for a
> **new PC**. The commands are for **Windows PowerShell**. Put every tool on the **same drive** as
> the project (here `E:`), see [Troubleshooting](#troubleshooting).

### 1. Git

Download and install it from https://git-scm.com/download/win.

### 2. Flutter SDK

```powershell
New-Item -ItemType Directory -Force E:\dev
git clone --depth 1 -b stable https://github.com/flutter/flutter.git E:\dev\flutter
```

### 3. JDK 17 (needed by Gradle; Java 21+/25 does not work)

Download the **Temurin 17 (Windows x64, .zip)** from https://adoptium.net/temurin/releases/?version=17
and extract it to `E:\dev\jdk\`. The result looks like `E:\dev\jdk\jdk-17.x.x+x\`.

### 4. Android SDK (command-line tools, no Android Studio needed)

1. Download the **Command line tools only (Windows)** zip from https://developer.android.com/studio#command-tools.
2. Extract it so the result is `E:\dev\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat`.
   The zip's `cmdline-tools` folder must be renamed to `latest`.
3. Install the packages and accept the licenses. Press `y` at every prompt:

```powershell
$env:JAVA_HOME = (Get-ChildItem E:\dev\jdk -Directory | Select-Object -First 1).FullName
$sdk = "E:\dev\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat"
& $sdk --sdk_root=E:\dev\Android\Sdk --licenses
& $sdk --sdk_root=E:\dev\Android\Sdk "platform-tools" "platforms;android-36" "build-tools;35.0.0"
```

### 5. Environment variables (user level, set once)

```powershell
[Environment]::SetEnvironmentVariable('ANDROID_HOME', 'E:\dev\Android\Sdk', 'User')
# Pub cache on the SAME drive as the project (otherwise the build fails, see Troubleshooting)
[Environment]::SetEnvironmentVariable('PUB_CACHE', 'E:\dev\pub-cache', 'User')
$p = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', "$p;E:\dev\flutter\bin;E:\dev\Android\Sdk\platform-tools", 'User')
```

**Close the terminal and open a new one** so the new PATH is loaded.

### 6. Flutter configuration

```powershell
$jdk = (Get-ChildItem E:\dev\jdk -Directory | Select-Object -First 1).FullName
flutter config --jdk-dir "$jdk" --android-sdk E:\dev\Android\Sdk --no-analytics
flutter doctor --android-licenses     # answer y to everything
flutter doctor                        # Flutter + Android toolchain must show [√]
```

### 7. Windows Developer Mode (required for plugins)

```powershell
start ms-settings:developers
```

Turn **Developer Mode** ON in the window that opens.

---

## Project setup

```powershell
# 1. Get the code
cd E:\pravin\applications
git clone https://github.com/pravin-python/pavan_residency.git
cd pavan_residency

# 2. Release signing key: copy these two files from your backup into the android\ folder
#    android\key.properties
#    android\pavan-release.jks
#    (see "Release signing key" below; they are NOT in git)

# 3. Libraries
flutter pub get

# 4. Check that everything is fine
flutter analyze        # "No issues found!"
flutter test           # "All tests passed!"
```

> The `android/` and `ios/` folders are already in the repo. You do **not** need to run `flutter create`.

---

## Running the app on a phone

1. On the phone: **Settings → About phone → tap "Build number" 7 times**, which turns Developer options on.
2. **Settings → Developer options → USB debugging** ON.
3. Connect the phone with a USB cable and tap **Allow** on the prompt that appears on the phone.
4. Then, in the project folder:

```powershell
adb devices            # the phone must show as "device" (not "unauthorized")
flutter run            # debug mode, hot reload with 'r'
flutter run --release  # release build, to check real-world speed
```

---

## Building the release APK / AAB

Follow these steps, in order, every time you release a new version.

### Step 1: Raise the version (every release)

In `pubspec.yaml`:

```yaml
version: 1.1.2+4      # before
version: 1.1.3+5      # after: raise the name (1.1.3) and ALWAYS raise the number after + (5)
```

> Play Store and Android only accept an update when the number after `+` (versionCode) goes up.

### Step 2: Clean, test and build

```powershell
cd E:\pravin\applications\pavan_residency

flutter clean
flutter pub get
flutter analyze
flutter test

# APK: to install directly on a phone or share on WhatsApp
flutter build apk --release

# AAB: for Google Play Store upload
flutter build appbundle --release
```

### Step 3: Output files

| File | Path |
|---|---|
| **APK** | `build\app\outputs\apk\release\Pavan_Residency-release.apk` |
| APK (same file, second copy) | `build\app\outputs\flutter-apk\app-release.apk` |
| **AAB** | `build\app\outputs\bundle\release\Pavan_Residency-release.aab` |

### Step 4 (optional): Check the signature

Make sure the release key was used and not the debug key:

```powershell
& "E:\dev\Android\Sdk\build-tools\35.0.0\apksigner.bat" verify --print-certs build\app\outputs\apk\release\Pavan_Residency-release.apk
# Must show: Signer #1 certificate DN: CN=Pavan Residency, O=Pavan Residency Co-op Hsg Soc Ltd, ...
```

> If `android\key.properties` is missing, a release build **stops with an error**
> (`android/key.properties is missing ...`). It never signs with the debug key silently.
> Debug builds (`flutter run`) still work without the key.

---

## Release signing key (important)

- Every release is signed with **`android\pavan-release.jks`** (alias `pavan`). Its password is in
  **`android\key.properties`**.
- Both files are **gitignored** and are never committed or pushed to GitHub.
- ⚠️ **Keep a backup of both files together** (Google Drive / USB drive / a second PC).
  **If the key is lost, the app can never be updated.** Phones reject an update signed with a
  different key, so everyone would have to uninstall and reinstall, and their settings would be lost.
- To build on another PC, copy the same two files into that PC's `android\` folder.
- The format is in `android\key.properties.example`:

```properties
storePassword=...
keyPassword=...
keyAlias=pavan
storeFile=../pavan-release.jks
```

Create a new key **only for a brand-new app id** (never for this app):

```powershell
& "E:\dev\jdk\<jdk-17-folder>\bin\keytool.exe" -genkeypair -v -keystore android\pavan-release.jks -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 -alias pavan
```

---

## Installing on a phone / Play Store

**Direct install (APK):**

```powershell
adb install -r build\app\outputs\apk\release\Pavan_Residency-release.apk
```

Or copy the APK to the phone or send it on WhatsApp, open it, and allow "Install unknown apps".

> **If an old version signed with a different key is installed** (for example the earliest
> debug-key APK), Android shows "App not installed". Uninstall it first. **Before
> uninstalling, note down Settings → Next Receipt No.** Uninstalling wipes the settings, and
> backup is off.

**Google Play:** in Play Console → your app → Production (or Internal testing) → Create
release, upload the `.aab` and turn on **Play App Signing**. For every update, raise the
version (Step 1) and upload a new `.aab`.

**After the first install:** fill in all the SMTP details in Settings and press **Save Settings**.
On the first save the app asks you to confirm **Next Receipt No.** It should be the last
number of the old phone / receipt book + 1.

---

## Gmail SMTP setup

1. Google Account → Security → turn **2-Step Verification** ON.
2. Open https://myaccount.google.com/apppasswords → create a new **App Password** (16 letters).
3. In the app's Settings:
   - Host `smtp.gmail.com`, port `465`, **SSL ON** (or port `587` with SSL OFF)
   - Username = Gmail address, Password = **App Password** (spaces are removed automatically)
4. Save Settings, then send one receipt from the Single tab to test.

> Gmail's normal password does not work, only the App Password. Gmail has a daily
> sending limit. When it is reached, Bulk stops by itself. Send the rest the next day.

---

## CSV format (Bulk)

A sample is in `assets/sample/pavan_bulk_sample.csv`. You can also get it with the
**"Download Sample CSV"** button on the Bulk tab.

```csv
receipt_no,block,house_no,name,amount,mode,cheque_no,type,transaction_number,bank_name,received_date,email,language,remarks
,A,101,Ramesh Patel,1500,Cash,,Maintenance,,,2026-09-25,ramesh@example.com,Gujarati,
,B,202,Suresh Shah,"25,000",Cheque,123456,Deposit,,SBI,2026-09-25,suresh@example.com,Hindi,
,C,303,John David,5000,Online,,Transfer fee,UTR458712369,HDFC,2026-09-26,john@example.com,English,
,A,104,Mahesh Joshi,700,Cash,,Other,,,,mahesh@example.com,Gujarati,Parking charges
```

**General**
- Export from Excel or Google Sheets as **CSV**. UTF-8, UTF-16, `,` / `;` / tab separated, and an Excel `sep=;` line all work.
- Column order does not matter and extra columns (e.g. `Received`, `OW/RENT`) are ignored. A title line above the header also works.
- Template rows (only `receipt_no` / `block` / `house_no` filled, with no name, email or amount) are skipped automatically.
- All values are **case-insensitive** (`Hindi` / `hindi` / `HINDI`).

**Columns**

| Column | Required? | Values / notes |
|---|---|---|
| `name` | ✔ | Resident's name |
| `email` | ✔ | One or more: `a@x.com, b@y.com`. Separate `Email 1` / `Email 2` columns also work. |
| `amount` | ✔ | `7500`, `7,500`, `Rs. 7,500/-`, `7500,00`. Whole rupees only, above 0 and below 100 crore. |
| `block` | | A / B / C (printed in capitals) |
| `house_no` | | Residence / shed no. |
| `type` | | `Maintenance` (also typos like `Maintance`), `Deposit`, `Transfer fee`, `Other`, or 1/2/3/4. **Other text** such as `Parking charges` or `Other - Parking` becomes Other + details. Blank = Maintenance. |
| `remarks` | | Details for type **Other** (printed on the Other row of the receipt) |
| `mode` | | `Cash` / `Cheque` / `Online`. UPI, NEFT, IMPS, GPay, PhonePe, Paytm, ઓનલાઈન and ऑनलाइन also mean Online. **Blank**: Cheque if there is a `cheque_no`, Online if there is a `transaction_number` or only a `bank_name`, otherwise Cash. |
| `cheque_no` | | Cheque number (a leading 0 is kept) |
| `transaction_number` | | UTR / reference no. (`utr`, `ref_no` also work) |
| `bank_name` | | For cheque or online (the old name `cheque_bank` also works) |
| `received_date` | | `2026-09-25`, `25/09/2026`, `25-Sep-2026`, `Sep 25, 2026`, an Excel date number. Excel month-first dates (`9/25/2026`) are detected for the whole file. |
| `date` | | Receipt date. If blank, `received_date` is used; if that is blank too, today's date. |
| `language` | | `Gujarati` / `Hindi` / `English` (or gu / hi / en). **Blank or not recognised = English.** |
| `receipt_no` | | **Leave it blank** for an auto number (recommended). If filled, it must be a positive whole number. |

A row with a problem shows **"✗ fix"** in the list, and a red line explains the reason (email, amount, date, receipt_no duplicate ...).

---

## Google Sheets (Bulk)

On the Bulk tab, **Google Sheets** is selected when the app starts. **CSV File** is one tap away and works exactly as before: the CSV workflow never touches Google, and nothing is ever written to a CSV file. If a Google Sheets step fails, the app shows the error and stays on Google Sheets; it never switches to CSV by itself.

The columns of the worksheet are the same as the [CSV format](#csv-format-bulk) (same names, same rules, same personalisation fields).

### One-time Google setup

1. [console.cloud.google.com](https://console.cloud.google.com) → create (or pick) a project.
2. **APIs & Services → Library**: enable **Google Sheets API** *and* **Google Drive API**. The Sheets API alone cannot list your spreadsheets; the Drive API is used only to list the spreadsheets shared with the account and to check edit rights (scope `drive.metadata.readonly`: it cannot read file contents). If you only paste spreadsheet links you can skip the Drive API.
3. **IAM & Admin → Service Accounts → Create service account** (no roles needed).
4. Open the account → **Keys → Add key → Create new key → JSON**. A `.json` file downloads.
5. In the app: **Settings → Google Sheets → Upload credentials**, choose that file. The app checks that it really is a service-account key and shows the email address of the account.
6. In Google Sheets open your spreadsheet → **Share** → paste that service-account email → **Editor**. A service account sees **only** spreadsheets shared with it; uploading the key does not give the app access to any of your other files.
7. Delete the downloaded JSON file from the phone (the app keeps its own protected copy).

**Billing:** the Google Sheets and Drive APIs and service accounts are free for this use; no billing account is needed. Quotas apply (about 60 write requests per minute per user). The app batches status writes (10 recipients per request) and retries on `429` / `5xx` with exponential back-off, so a normal run stays far below them.

### Using it

1. **Bulk → Google Sheets**: tap the search icon to list the spreadsheets shared with the account (or the link icon to paste a link / ID), choose the spreadsheet, then the **worksheet tab**. The choice is remembered.
2. **Load recipients** (also the refresh button). Only the selected tab is read. Each row shows its real sheet row number and the current status. `TRUE` rows are shown as sent and skipped (long-press to send again); `FALSE` and blank rows are ready.
3. **Send All Emails** works as before (parallel sending, Stop, receipt numbers). Before the first email the app checks that the spreadsheet and tab are reachable, that the account may edit them, and that the status column exists. If not, **nothing is sent**.
4. After each email: confirmed delivered → `TRUE`; certainly not delivered (login refused, address refused...) → `FALSE`. If delivery is **uncertain** (the connection dropped after sending) nothing is written, because `FALSE` could cause a duplicate email.
5. If the email went out but the sheet could not be updated, the row says **"Email sent, but its status could not be saved to the sheet"** (never "failed"), and a **Save N pending statuses** button writes them later. Reloading the sheet never re-sends those emails: the phone remembers what it sent.

### Status column

- Title: `email_sent` by default; change it in Settings → Google Sheets. `Email_Sent`, `email sent` and `EMAIL SENT` are the same column. A recipient column name such as `email` is refused.
- Found → updated. Not found → the title is added **once**, after the last used column (never over data), and the grid is widened if it is full. It is never duplicated on later runs.
- Only status cells (and that one header cell) are written. Other columns, values and formulas are untouched; no row is ever appended.
- Each write is checked first: the recipient's email cell must still be at the remembered row. If rows were inserted or deleted meanwhile the row is found again by its email; if that is ambiguous the status is **not** written and the row asks you to reload.

### Security notes and limits

- The key is stored only in Android-Keystore-backed secure storage (`flutter_secure_storage`), reduced to the fields needed for signing in. It is not in SharedPreferences, not in the source, not in logs or error messages, and not in backups (`allowBackup=false`).
- **A phone-held key is a trade-off.** Anyone who gets the JSON file (or a rooted phone) can act as that service account on the spreadsheets shared with it. Share only what is needed and revoke a lost key in Google Cloud (Service Accounts → Keys). A more secure design keeps the key on a server (for example a Cloud Function or Apps Script web app that exposes only "list tabs / read rows / set status") and the app only holds a revocable token. That needs a backend and is not part of this app; this version is the direct-upload design.
- Google does not offer a compare-and-set for cells: between the row check and the write another editor could still change the sheet. The window is a fraction of a second.
- Hidden / filtered rows are treated like any other row. Merged header cells are not supported.

---

## Receipt number rules

- **Next Receipt No.** is in Settings. It goes up by 1 after every successful send (794, 795, 796 ...).
- If a number was taken for a send that then certainly failed, and a later number was already taken meanwhile (parallel sends), it is kept as a **spare** and used for the next receipt. Spares are saved with the settings, so there are no gaps even after the app restarts.
- Single and Bulk **reserve** the number when a send starts, so the same number can never be used twice, even when both run at the same time.
- If a mail is **certainly not sent** (wrong password, no internet, server refused), its number is released and the next receipt gets it (no gap).
- If a mail **may have been sent** (the connection dropped mid-send), the number stays used. The app says "Not sure whether the email was delivered"; check the Sent folder. A retry sends the same number again.
- The app warns you if you type or use a number that may already have been used (below the counter).
- Reinstall / new phone: backup is off, so the counter goes back to its default. **Confirm it** on the first Save.

---

## Permissions

| Permission | Why |
|---|---|
| `INTERNET` | To send email over SMTP |
| `ACCESS_NETWORK_STATE` | To check the network state |

(`INTERNET` is also what Google Sheets uses. No other permission is added.)

- **No storage permission, on purpose.** Picking the CSV and the signature and "Download Sample CSV"
  all go through Android's system file dialog (Storage Access Framework), which needs no permission.
  `MANAGE_EXTERNAL_STORAGE` / storage permissions would get the app rejected by Play Store.
- **Backup is off** (`allowBackup=false` + `data_extraction_rules.xml`), so the SMTP password never
  goes to Google Drive backup or a phone-to-phone transfer.
- During Bulk send the screen **stays on** (wakelock_plus). This needs no permission.

---

## Project structure

```
lib/
  main.dart                    # app + theme
  models/receipt_data.dart     # receipt model; CSV value parsing (mode/type/amount/email)
  services/
    amount_words.dart          # amount → words (gu/hi/en, lakh-crore) + Indian grouping
    receipt_l10n.dart          # receipt labels in 3 languages
    receipt_html.dart          # email-safe HTML receipt (universal payment block)
    pdf_service.dart           # vector PDF (A5), Noto fonts, footer pinned
    email_service.dart         # SMTP send (mailer), friendly errors, sent / not-sent
    csv_service.dart           # CSV decode, header/column mapping, dates
    settings_service.dart      # SharedPreferences settings + receipt counter
    sent_log.dart              # which receipts were already mailed (no re-send)
    signature_image.dart       # signature resize / validation
    sheets/
      google_credentials.dart  # service-account key parsing + validation
      credential_store.dart    # secure (Keystore) storage of the key
      sheets_api.dart          # Sheets v4 / Drive v3 REST client, retries, A1 helpers
      sheets_config.dart       # remembered spreadsheet / tab / status title, link parsing
      sheet_layout.dart        # header row, email column, status column detection
      sheet_recipient_reader.dart  # worksheet -> recipients (reuses CsvService rules)
      sheet_status_writer.dart # status column creation, verified batched writes
      sheets_service.dart      # signed-in API + per-run session (pre-send checks)
  widgets/
    sheets_source_panel.dart   # Bulk: spreadsheet / tab pickers, load / refresh
    sheets_settings_section.dart # Settings: credentials, status title, instructions
  screens/
    home_screen.dart           # bottom navigation (Single / Bulk / Settings)
    single_screen.dart         # single receipt form
    bulk_screen.dart           # source (Sheets / CSV), Send All, Stop
    settings_screen.dart       # SMTP + signature + receipt + Google Sheets settings
  utils/file_saver*.dart       # "Save as" dialog (sample CSV)
assets/
  fonts/                       # Noto Sans (Gujarati, Devanagari, Latin)
  sample/pavan_bulk_sample.csv # sample CSV
  icon/                        # launcher icon (dart run flutter_launcher_icons)
android/
  app/build.gradle.kts         # release signing (+ guard), APK name Pavan_Residency-*
  app/src/main/AndroidManifest.xml
  app/src/main/res/xml/data_extraction_rules.xml
  key.properties.example       # signing file format (the real key.properties is NOT in git)
test/                          # flutter test
```

---

## Tests

```powershell
flutter test                          # all tests
flutter test test\csv_service_test.dart   # a single file
flutter analyze                       # lint / static checks
```

The tests cover CSV parsing (formats, dates, amounts, modes/types), receipt numbering,
the sent log, the signature, error messages, and the small-phone / large-font layout.

`test\sheets\` covers Google Sheets against an in-memory Google backend (`fake_google.dart`): credential
validation and secure storage, spreadsheet / tab selection, header detection, status column
creation / reuse / no duplicates, correct-row writes without touching other data, retries and
failures, and the full Bulk screen (real SMTP sockets) for TRUE / FALSE / "sent but status not saved".
`test\flutter_test_config.dart` swaps in an in-memory secure storage, so the real Android Keystore
is **not** exercised by the automated tests.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `'flutter' is not recognized` | Open a new terminal after setting PATH, or check PATH in step 5. |
| Build: `Execution failed for task ':printing:packageDebugResources' ... Error: ->` | The pub cache is on a different drive (C:) from the project (E:). Set `PUB_CACHE=E:\dev\pub-cache`, then run `flutter clean` and `flutter pub get`. |
| `Building with plugins requires symlink support` | Turn on Windows **Developer Mode** (`start ms-settings:developers`). |
| Gradle / Java version error | Gradle needs JDK 17: `flutter config --jdk-dir "E:\dev\jdk\jdk-17..."` |
| `android/key.properties is missing - refusing to build a release ...` | Copy `key.properties` + `pavan-release.jks` from your backup into `android\`. |
| Phone says "App not installed" / `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | The installed app was signed with a different key. Note down Next Receipt No., uninstall, then install. |
| `adb devices` shows `unauthorized` | Tap "Allow USB debugging" on the phone, or reconnect the cable. |
| Email: "Login failed" | Use a Gmail App Password (not the normal password) and turn 2-Step Verification ON. |
| Email: "SSL error" | Port 465 → SSL ON, port 587 → SSL OFF. |
| Bulk: "The mail server is not accepting emails right now (daily limit reached ...)" | Gmail's daily limit is reached. Try again after a few hours or the next day. Already-sent rows are skipped. |
| First build is very slow | Gradle / NDK download the first time (10–15 min). Later builds take 1–3 min. |

---

© Pavan Residency (Bhadaj) Co-op Housing Society maintained by
[pravin-python](https://github.com/pravin-python).
