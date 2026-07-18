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

### Android release APK
```bash
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
```

## Gmail SMTP

1. Google Account → Security → **2-Step Verification** ON karo.
2. **App Passwords** → naya password banao (16 letters).
3. App Settings mein: host `smtp.gmail.com`, port `465`, SSL ON, username = Gmail address, password = app password.

## CSV format

`assets/sample/pavan_bulk_sample.csv` dekho:

```csv
name,email,block,house_no,amount,cheque_no,cheque_bank,language,type,date
Ramesh Patel,ramesh@example.com,A,101,1500,123456,SBI,gujarati,maintenance,2026-07-18
Suresh Shah,suresh@example.com,B,202,25000,,,hindi,deposit,
John David,john@example.com,C,303,5000,998877,HDFC,english,transfer,
```

- `language`: gujarati / hindi / english (ya gu / hi / en)
- `type`: maintenance / deposit / transfer / other (ya 1 / 2 / 3 / 4)
- `cheque_no` blank = Cash receipt
- `receipt_no`, `date` optional — blank par auto number + aaj ki date

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
