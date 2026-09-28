# Pavan Residency — Receipt Mailer (Flutter)

Android + iOS app for Pavan Residency (Bhadaj) Co-op Housing Society.
Creates maintenance receipts in **Gujarati / Hindi / English** and emails them
via **your own SMTP** (settings stored on the phone) — single entry or bulk CSV.

## Features

- **Single**: form bharo → PDF preview → email send.
- **Bulk CSV**: CSV upload karo → har row ka receipt alag language/type ke saath → Send All (per-row status).
- **Settings** (device par save, SharedPreferences):
  - SMTP host / port / SSL / username / password, sender name.
  - Signature image (jpg / jpeg / png) — email mein inline + PDF mein bhi.
  - Subject template, PDF attach on/off, auto-increment receipt number.
- Receipt design society ki printed receipt book jaisa (red/pink), amount **words mein** teeno bhasha mein (Indian system — lakh/crore).
- Email body mein HTML receipt + proper vector **PDF attachment** (A5 landscape, embedded Noto fonts).

## Setup (first time)

```bash
# 1. Flutter SDK install hona chahiye (flutter.dev/docs/get-started/install)
cd pavan_residency

# 2. Platform folders generate karo (android/, ios/)
flutter create . --org com.pavanresidency --project-name pavan_residency

# 3. Dependencies
flutter pub get

# 4. Run (device/emulator connected)
flutter run
```

> `flutter create .` sirf missing platform folders banata hai — `lib/`, `pubspec.yaml`, `assets/` ko touch nahi karta.

### iOS note
`ios/Runner/Info.plist` — file picker ke liye kuch nahi chahiye (file_picker document picker use karta hai). Build ke liye Mac + Xcode zaroori hai:
```bash
flutter build ios
```

### Android release (APK / Play Store)

Release builds are signed with **`android/pavan-release.jks`** using the values in
**`android/key.properties`**. Both files are gitignored. **Back them up together**
(Google Drive / pendrive). Every future update must be signed with this same key,
otherwise installed phones will refuse the update. Without `key.properties` a
release build stops with an error. It never falls back to the debug key.

```bash
# Direct install / WhatsApp share:
flutter build apk --release
# output: build/app/outputs/apk/release/Pavan_Residency-release.apk

# Google Play upload (Play needs an .aab):
flutter build appbundle --release
# output: build/app/outputs/bundle/release/Pavan_Residency-release.aab
```

Before every new release, raise the build number in `pubspec.yaml`, e.g.
`version: 1.1.0+2` → `1.1.1+3`.

### Permissions

- `INTERNET` + `ACCESS_NETWORK_STATE` are used to send email over SMTP.
- **No storage permission.** Picking the CSV and the signature, and "Download Demo CSV",
  all go through the Android system file dialog, which needs no permission.
  `MANAGE_EXTERNAL_STORAGE` would get the app rejected by Play.
- Backup is off (`allowBackup=false`), so the SMTP password is never copied to
  Google Drive or to a new phone. After a reinstall or a phone change, fill in Settings again.
- During Bulk send the screen stays on (wakelock). This needs no permission.

## Gmail SMTP

1. Google Account → Security → **2-Step Verification** ON karo.
2. **App Passwords** → naya password banao (16 letters).
3. App Settings mein: host `smtp.gmail.com`, port `465`, SSL ON, username = Gmail address, password = app password.

## CSV format

`assets/sample/pavan_bulk_sample.csv` dekho:

```csv
receipt_no,block,house_no,name,amount,mode,cheque_no,type,transaction_number,bank_name,received_date,email,language,remarks
1,A,101,Ramesh Patel,1500,Cash,,Maintance,,,2026-09-25,ramesh@example.com,Gujarati,
2,B,202,Suresh Shah,"25,000",Cheque,123456,Deposit,,SBI,2026-09-25,suresh@example.com,Hindi,
3,C,303,John David,5000,Online,,Transfer fee,UTR458712369,HDFC,2026-09-26,john@example.com,English,
,A,104,Mahesh Bhai,700,Cash,,Other,,,,mahesh@example.com,Gujarati,Parking charges
```

- Column order kuch bhi ho sakta hai; extra columns ignore hote hain. Excel / Google Sheets se **CSV** export karo.
- `language`: gujarati / hindi / english (ya gu / hi / en)
- Saari values **case-insensitive** hain (`Hindi` / `hindi` / `HINDI` sab chalega).
- `block`: A / B / C (small letter bhi chalega, receipt par capital chhapega)
- `type`: maintenance (`Maintance` bhi) / deposit / transfer fee / other (ya 1 / 2 / 3 / 4)
- `remarks`: type **Other** ho to yeh text receipt ki "Other" line mein chhapta hai (max ~60 akshar).
  `remarks` column na ho to type mein hi text likh do (jaise `Parking charges`) — woh Other + details ban jayega.
- `mode`: cash / cheque / online (UPI / NEFT / IMPS bhi chalega).
  Blank ho to: `cheque_no` hai → Cheque, `transaction_number` hai → Online, warna Cash.
- `bank_name` (purana naam `cheque_bank` bhi chalega) — cheque ya online dono ke liye.
- `amount` mein `7,500` / `Rs. 7500` jaisa format chalega.
- `received_date`: `2026-09-25` ya `25/09/2026`. Receipt ki date = `date` column, woh na ho to `received_date`, woh bhi na ho to aaj ki date.
- `receipt_no` optional — blank par auto number.

## Project structure

```
lib/
  main.dart                    # app + theme
  models/receipt_data.dart     # receipt model, CSV value parsing
  services/
    amount_words.dart          # amount → words (gu/hi/en, lakh-crore)
    receipt_l10n.dart          # receipt labels in 3 languages
    receipt_html.dart          # email-safe HTML receipt
    pdf_service.dart           # vector PDF (A5) with Noto fonts
    email_service.dart         # SMTP send (mailer) + inline signature (cid)
    csv_service.dart           # CSV parse + column mapping
    settings_service.dart      # SharedPreferences persistence
  screens/
    home_screen.dart           # bottom navigation
    single_screen.dart         # single receipt form
    bulk_screen.dart           # CSV upload + send all
    settings_screen.dart       # SMTP + signature + receipt settings
assets/
  fonts/                       # Noto Sans (Gujarati, Devanagari, Latin)
  sample/pavan_bulk_sample.csv
test/
  amount_words_test.dart       # run: flutter test
```

## Tests

```bash
flutter test
```
