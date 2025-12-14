# Firebase Analytics Setup Guide

This guide will walk you through setting up Firebase Analytics for the Kitzi app.

## Prerequisites

- A Google account
- Access to [Firebase Console](https://console.firebase.google.com/)

## Step 1: Create a Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Click **"Add project"** or **"Create a project"**
3. Enter your project name (e.g., "Kitzi ABS Player")
4. (Optional) Enable Google Analytics for your project
5. Click **"Create project"**
6. Wait for the project to be created, then click **"Continue"**

## Step 2: Add Android App to Firebase

1. In your Firebase project, click the **Android icon** (or **"Add app"** → **Android**)
2. Enter your Android package name: `com.bennybar.kitzi`
3. (Optional) Enter app nickname: "Kitzi Android"
4. (Optional) Enter debug signing certificate SHA-1 (for testing)
   - To get your SHA-1: Run `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android`
5. Click **"Register app"**
6. Download the `google-services.json` file
7. Place the file in: `android/app/google-services.json`
   ```bash
   # From project root:
   cp ~/Downloads/google-services.json android/app/
   ```

## Step 3: Add iOS App to Firebase

1. In your Firebase project, click the **iOS icon** (or **"Add app"** → **iOS**)
2. Enter your iOS bundle ID: `com.bennybar.kitzi` (check `ios/Runner/Info.plist` for actual bundle ID)
3. (Optional) Enter app nickname: "Kitzi iOS"
4. (Optional) Enter App Store ID (if published)
5. Click **"Register app"**
6. Download the `GoogleService-Info.plist` file
7. Place the file in: `ios/Runner/GoogleService-Info.plist`
   ```bash
   # From project root:
   cp ~/Downloads/GoogleService-Info.plist ios/Runner/
   ```

## Step 4: Install Dependencies

Run Flutter pub get to install Firebase packages:

```bash
flutter pub get
```

## Step 5: iOS Additional Setup

1. Open `ios/Runner.xcworkspace` in Xcode
2. Make sure `GoogleService-Info.plist` is added to the Runner target:
   - In Xcode, right-click on `Runner` folder
   - Select "Add Files to Runner..."
   - Select `GoogleService-Info.plist`
   - Make sure "Copy items if needed" is checked
   - Make sure "Runner" target is selected
   - Click "Add"

3. Update `ios/Podfile` to ensure Firebase pods are installed:
   ```ruby
   # This should already be handled by FlutterFire, but verify
   platform :ios, '12.0'
   ```

4. Install iOS pods:
   ```bash
   cd ios
   pod install
   cd ..
   ```

## Step 6: Verify Setup

1. Build and run the app:
   ```bash
   flutter run
   ```

2. Check the logs for Firebase initialization:
   ```
   [Main] Firebase initialized successfully
   [FirebaseAnalytics] Initialized
   [FirebaseAnalytics] App open logged
   ```

3. In Firebase Console, go to **Analytics** → **Events**
4. Wait a few minutes, then check if `app_open` events are appearing

## Step 7: View Analytics

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Select your project
3. Navigate to **Analytics** → **Dashboard**
4. You'll see:
   - **Daily Active Users (DAU)**
   - **Monthly Active Users (MAU)**
   - **Events** (app_open, book_play, book_download, etc.)
   - **User engagement metrics**

## Troubleshooting

### Android: "google-services.json not found"
- Make sure `google-services.json` is in `android/app/` directory
- Verify the file name is exactly `google-services.json` (case-sensitive)
- Clean and rebuild: `flutter clean && flutter pub get && flutter run`

### iOS: "GoogleService-Info.plist not found"
- Make sure `GoogleService-Info.plist` is in `ios/Runner/` directory
- Verify it's added to the Xcode project and Runner target
- Run `pod install` in the `ios/` directory

### Firebase not initializing
- Check that you have internet connection
- Verify the package name/bundle ID matches Firebase project
- Check logs for specific error messages
- Make sure `google-services.json` / `GoogleService-Info.plist` are valid JSON/XML

### No events showing in Firebase Console
- Events can take 24-48 hours to appear in the console
- Make sure you're looking at the correct Firebase project
- Check that Analytics is enabled in Firebase project settings
- Verify the app is actually running and calling analytics methods

## What Gets Tracked

The app automatically tracks:
- **App opens** (daily active users)
- **Screen views** (when navigating between pages)
- **Book plays** (when user starts playing a book)
- **Book downloads** (when user downloads a book)

All tracking is privacy-compliant and anonymized by Firebase.

## Privacy

Firebase Analytics is GDPR and CCPA compliant. User data is anonymized and aggregated. No personally identifiable information (PII) is collected by default.

