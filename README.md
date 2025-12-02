# ReceiptManager iOS

ReceiptManager is a SwiftUI-based iOS application for scanning receipts (single or multiple), cropping to remove noise, then extracting different receipt components (Store name, Date, Time, Items and their respective price, Tax, and Total). After the extraction is done, you are allowed to edit extracted fields, then upload both the image and receipt components to the database.

## Features

* Multi-shot camera capture with live preview
* Per-image cropping
* On-device OCR (Apple Vision), which produces:
  * Structured document: store, date/time, totals, line items
* The ability to edit the receipt details before upload
* Swift Concurrency used across camera, OCR, and networking for speed
  
## Database integration

  * Upload stitched image to Firebase Storage
  * Upload metadata to Firestore
  * Optional folder organization for receipts

## Requirements

* Xcode 15+
* iOS 16+
* Firebase project configured with:
  * Authentication (app expects a signed-in user)
  * Firestore
  * Storage
* `GoogleService-Info.plist` added to the iOS target
* Real iOS device required for camera & OCR testing

## Quickstart

### 1. Clone the repo and open it in Xcode.
### 2. Install Swift Package Dependencies:
   * `FirebaseAuth`
   * `FirebaseFirestore`
   * `FirebaseStorage`
   * `CropViewController`
  
### 3. Configure Firebase:
   * Create a Firebase project
   * Enable authentication provider(s)
   * Enable Firestore & Storage
   * `Add GoogleService-Info.plist` to the app target
   
### 4. Update Info.plist
   
### 5. Build & run on a device
   * Sign in before uploading receipts

## How It Works

### 1. Log in to an account

* `SignInView` sets up the `SessionViewModel` for login UI
* Users can log in through email/password or Sign In With Google


### 2. Capture

* `CameraController` sets up the `AVCaptureSession`
* `CameraPreviewView` renders `AVCaptureVideoPreviewLayer` in SwiftUI
* Captured frames are held in memory until cropping

### 3. Crop

* `MultiCropView` hosts `CropViewController` wrappers per image
* Images are auto-scaled (max width ≈ 1080 px) to limit memory usage

### 4. OCR (Extract Text)

* `OCRService` uses `VNRecognizeTextRequest` to extract raw text from receipts
* Outputs:
  * tokens
  * rawText
 
### 5. Populate receipt fields
* `ReceiptItemClassifier` Machine Learning model handles itemization
* Combined with a parsing pipeline in `OCRService` produces a `ReceiptDocument` with the following pre-filled:

  * store name
  * date & time
  * totals & tax
  * items

### 6. Edit

* `EditReceiptView` lets users correct errors (which do happen):
  * For the following fields: Store, date, totals, payment method, items

### 7. Upload

* `FirestoreService` handles uploading the data to the connected Firestore database

### 8. See Receipts and Filterable Statistics

* `StatisticsView` will display the receipt data statistics attached to the current user

## Architecture Overview

### SwiftUI Views

* `AddReceiptsView` - Pop-up for where a receipt is uploaded
* `CameraPreviewView` - Connects to the camera to see what's visible
* `ContentView` - The main landing page with tabs for scanning, receipts, and stats
* `ReceiptDetailView` - Displays the relevant data from the receipt
* `OCRDebugView` - Used to debug the OCR (pop-up of raw text from OCR)
* `CropView` - Shows the UI for the cropping after a picture is taken
* `EditReceiptView` - Shows the UI for adding/editing information slots
* `FolderDetailView` - Shows the UI for seeing information in folders
* `SignInView` - Shows the login UI (email/password or Google Sign-in)
* `ScanView` — capture, crop, OCR, edit, upload
* `MultiCropView` + `CropView` — per-image cropping
* `ReceiptsView` — list receipts, folders, move-to-folder
* `StatisticsView` - Shows the UI for the statistics page

### Services
* `AuthService` - Create Account/Log in through Email/Password or Google Sign-In
* `CameraController` — capture session management
* `OCRService` — Vision OCR + parsing pipeline
* `ReceiptUploader` — Storage upload
* `FirestoreService` — Create, Read, Update, and Delete receipts & folders

### Data Models
* `OCRModels` - Initializes all types of data that can be extracted from a receipt
* `SessionViewModel` - Responsible for tracking the current authentication/session state

### Machine Learning Model
* `MLItemClassifier` - Creates a usable instance of the model
* `ReceiptItemClassifier` - The trained text classification model

### Concurrency

* Heavy use of async/await
* Camera operations use background queues for safety

## Troubleshooting

| Issue                         | Fix                                                          |
| ----------------------------- | ------------------------------------------------------------ |
| Black camera preview          | Check permissions, ensure session started                    |
| "Not signed in"               | Confirm Auth configuration                                   |
| Firestore "permission denied" | Verify rules + correct user path                             |
| Storage upload fails          | Confirm Storage rules & presence of GoogleService-Info.plist |
| Itemization Accuracy          | Build a dataset and train your own itemization model         |

## Future Ideas/Implementations

* Auto-edge detection + auto-capture
* PDF exporting abilities
* OCR confidence visualization
* Write the uploaded data to a Smart Contract on the Blockchain
* Train a model on a large dataset (~1000 item instances)

## Contributions

Pull requests welcome!
Please include tests and clearly describe changes.


## 📄 License

Coming soon...

## Creators

* Michael Tong
* Merrick Fort
* Bronsen Lasala
* Nate Bagchee

