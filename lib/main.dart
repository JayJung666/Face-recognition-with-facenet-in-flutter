import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:permission_handler/permission_handler.dart'
    as permissionHandler;
import 'ml.dart'; // Import the ml.dart file

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Dapatkan daftar kamera yang tersedia
  final cameras = await availableCameras();
  final firstCamera = cameras.firstWhere(
    (camera) => camera.lensDirection == CameraLensDirection.front,
    orElse: () => cameras.first,
  );

  runApp(MaterialApp(
    title: 'Aplikasi Verifikasi Wajah',
    theme: ThemeData(
      primarySwatch: Colors.blue,
      visualDensity: VisualDensity.adaptivePlatformDensity,
    ),
    home: FaceVerificationApp(camera: firstCamera),
    debugShowCheckedModeBanner: false,
  ));
}

class FaceVerificationApp extends StatefulWidget {
  final CameraDescription camera;

  const FaceVerificationApp({Key? key, required this.camera}) : super(key: key);

  @override
  _FaceVerificationAppState createState() => _FaceVerificationAppState();
}

class _FaceVerificationAppState extends State<FaceVerificationApp> {
  // Controller untuk kamera
  late CameraController _cameraController;
  late Future<void> _initializeControllerFuture;

  // Instance untuk image picker
  final ImagePicker _picker = ImagePicker();

  // File untuk menyimpan gambar
  File? _referenceImage;
  File? _capturedImage;

  // State aplikasi
  bool _isCameraActive = false;
  bool _isProcessing = false;
  bool _isFrontCamera = true;

  // Langkah proses verifikasi
  int _currentStep = 0;

  // Hasil verifikasi
  Map<String, dynamic>? _verificationResult;

  // Face detector dari ML Kit
  final FaceDetector _faceDetector = GoogleMlKit.vision.faceDetector(
    FaceDetectorOptions(
      enableClassification: true,
      enableLandmarks: true,
      enableTracking: false,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  // Tambahkan instance FaceEmbeddingModel
  final FaceEmbeddingModel _faceEmbeddingModel = FaceEmbeddingModel();

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initializeCamera(widget.camera);
  }

  Future<void> _requestPermissions() async {
    // Minta izin untuk kamera dan penyimpanan
    await [
      permissionHandler.Permission.camera,
      permissionHandler.Permission.storage,
    ].request();
  }

  void _initializeCamera(CameraDescription cameraDescription) {
    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    _initializeControllerFuture = _cameraController.initialize();
  }

  void _switchCamera() async {
    // Dapatkan daftar kamera yang tersedia
    final cameras = await availableCameras();

    // Cari kamera depan/belakang
    CameraDescription selectedCamera;
    if (_isFrontCamera) {
      selectedCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
    } else {
      selectedCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
    }

    // Dispose controller lama
    await _cameraController.dispose();

    // Update state
    setState(() {
      _isFrontCamera = !_isFrontCamera;
    });

    // Inisialisasi controller baru
    _initializeCamera(selectedCamera);

    // Tunggu hingga kamera selesai diinisialisasi
    await _initializeControllerFuture;

    // Pastikan kamera tetap aktif
    setState(() {
      _isCameraActive = true;
    });
  }

  @override
  void dispose() {
    // Dispose resources
    _cameraController.dispose();
    _faceDetector.close();
    super.dispose();
  }

  // Fungsi untuk memilih gambar referensi dari galeri
  Future<void> _pickReferenceImage() async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1080,
        maxHeight: 1080,
        imageQuality: 90,
      );

      if (pickedFile != null) {
        // Reset hasil verifikasi jika ada
        setState(() {
          _verificationResult = null;
          _capturedImage = null;
        });

        // Deteksi wajah pada gambar referensi
        final inputImage = InputImage.fromFilePath(pickedFile.path);
        final List<Face> faces = await _faceDetector.processImage(inputImage);

        if (faces.isNotEmpty) {
          setState(() {
            _referenceImage = File(pickedFile.path);
            _isCameraActive =
                true; // Aktifkan kamera setelah memilih gambar referensi
            _currentStep = 1; // Pindah ke langkah berikutnya
          });
          _showSnackBar('Gambar referensi berhasil dipilih');
        } else {
          _showSnackBar(
              'Tidak ada wajah terdeteksi pada gambar. Silakan pilih gambar lain.');
        }
      }
    } catch (e) {
      _showSnackBar('Error memilih gambar: $e');
    }
  }

  // Fungsi untuk mengambil gambar dari kamera
  Future<void> _takePicture() async {
    if (_referenceImage == null) {
      _showSnackBar('Pilih gambar referensi terlebih dahulu');
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      await _initializeControllerFuture;

      final XFile photo = await _cameraController.takePicture();

      // Deteksi wajah pada gambar yang diambil
      final inputImage = InputImage.fromFilePath(photo.path);
      final List<Face> faces = await _faceDetector.processImage(inputImage);

      if (faces.isNotEmpty) {
        setState(() {
          _capturedImage = File(photo.path);
          _isCameraActive = false;
          _currentStep = 2; // Update langkah
        });

        // Proses verifikasi
        await _verifyFaces();
      } else {
        _showSnackBar(
            'Tidak ada wajah terdeteksi pada gambar. Silakan coba lagi.');
      }
    } catch (e) {
      _showSnackBar('Error mengambil gambar: $e');
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  // Fungsi untuk mengambil ulang gambar
  void _retakePicture() {
    setState(() {
      _capturedImage = null;
      _verificationResult = null;
      _isCameraActive = true;
      _currentStep = 1; // Kembali ke langkah mengambil gambar
    });
  }

  // Fungsi utama untuk verifikasi wajah
  Future<void> _verifyFaces() async {
    if (_referenceImage == null || _capturedImage == null) {
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      // Ekstrak embedding wajah dari gambar referensi dan gambar yang diambil
      List<double> refEmbedding =
          await _faceEmbeddingModel.getEmbedding(_referenceImage!);
      List<double> capturedEmbedding =
          await _faceEmbeddingModel.getEmbedding(_capturedImage!);

      // Hitung kesamaan menggunakan cosine similarity
      double similarity = cosineSimilarity(refEmbedding, capturedEmbedding);

      // Threshold untuk menentukan kecocokan
      final double threshold = 0.7;

      setState(() {
        if (similarity >= threshold) {
          _verificationResult = {
            'isMatch': true,
            'message': 'Verifikasi berhasil! Wajah terverifikasi.',
            'similarity': similarity,
          };
        } else {
          _verificationResult = {
            'isMatch': false,
            'message': 'Verifikasi gagal. Wajah tidak cocok.',
            'similarity': similarity,
          };
        }
      });
    } catch (e) {
      setState(() {
        _verificationResult = {
          'isMatch': false,
          'message': 'Error saat verifikasi: $e',
          'similarity': 0.0,
        };
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  // Reset proses
  void _resetProcess() {
    _showConfirmationDialog();
  }

  // Dialog konfirmasi reset
  Future<void> _showConfirmationDialog() async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Konfirmasi Reset'),
          content: const Text(
              'Apakah Anda yakin ingin mereset proses verifikasi wajah?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Batal'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Reset'),
              onPressed: () {
                Navigator.of(context).pop();
                setState(() {
                  _verificationResult = null;
                  _capturedImage = null;
                  _referenceImage = null;
                  _isCameraActive = false;
                  _currentStep = 0; // Kembali ke langkah awal
                });
              },
            ),
          ],
        );
      },
    );
  }

  // Helper untuk menampilkan snackbar
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // Fungsi untuk mendapatkan teks instruksi berdasarkan langkah saat ini
  String _getInstructionText() {
    switch (_currentStep) {
      case 0:
        return 'Langkah 1: Pilih gambar referensi dari galeri';
      case 1:
        return 'Langkah 2: Ambil gambar wajah untuk verifikasi';
      case 2:
        return 'Langkah 3: Hasil verifikasi wajah';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aplikasi Verifikasi Wajah'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Stepper progress indicator
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _getInstructionText(),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color:
                                _currentStep >= 0 ? Colors.blue : Colors.grey,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color:
                                _currentStep >= 1 ? Colors.blue : Colors.grey,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color:
                                _currentStep >= 2 ? Colors.blue : Colors.grey,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Area gambar
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  // Gambar referensi
                  Expanded(
                    child: Column(
                      children: [
                        const Text(
                          'Gambar Referensi',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: 150,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: _referenceImage != null
                              ? Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(
                                        _referenceImage!,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    Positioned(
                                      top: 5,
                                      right: 5,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.7),
                                          shape: BoxShape.circle,
                                        ),
                                        child: IconButton(
                                          icon: const Icon(Icons.refresh),
                                          iconSize: 20,
                                          onPressed: _currentStep < 2
                                              ? _pickReferenceImage
                                              : null,
                                          tooltip: 'Ganti gambar referensi',
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : const Center(
                                  child: Text('Belum ada gambar'),
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Gambar dari kamera
                  Expanded(
                    child: Column(
                      children: [
                        const Text(
                          'Gambar Kamera',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: 150,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: _capturedImage != null
                              ? Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(
                                        _capturedImage!,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    Positioned(
                                      top: 5,
                                      right: 5,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.7),
                                          shape: BoxShape.circle,
                                        ),
                                        child: IconButton(
                                          icon: const Icon(Icons.refresh),
                                          iconSize: 20,
                                          onPressed: _isProcessing
                                              ? null
                                              : _retakePicture,
                                          tooltip: 'Ambil ulang gambar',
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: _isCameraActive
                                      ? FutureBuilder<void>(
                                          future: _initializeControllerFuture,
                                          builder: (context, snapshot) {
                                            if (snapshot.connectionState ==
                                                ConnectionState.done) {
                                              return CameraPreview(
                                                  _cameraController);
                                            } else {
                                              return const Center(
                                                  child:
                                                      CircularProgressIndicator());
                                            }
                                          },
                                        )
                                      : const Center(
                                          child: Text('Kamera tidak aktif'),
                                        ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Hasil verifikasi
            if (_verificationResult != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _verificationResult!['isMatch']
                        ? Colors.green.shade100
                        : Colors.red.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _verificationResult!['isMatch']
                                ? Icons.check_circle
                                : Icons.cancel,
                            color: _verificationResult!['isMatch']
                                ? Colors.green.shade900
                                : Colors.red.shade900,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _verificationResult!['message'],
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _verificationResult!['isMatch']
                                    ? Colors.green.shade900
                                    : Colors.red.shade900,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Similarity: ${(_verificationResult!['similarity'] * 100).toStringAsFixed(2)}%',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _verificationResult!['isMatch']
                            ? 'Verifikasi berhasil diselesaikan'
                            : 'Anda dapat mencoba lagi dengan gambar yang berbeda',
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: _verificationResult!['isMatch']
                              ? Colors.green.shade700
                              : Colors.red.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Tombol aksi
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  // Tombol berdasarkan langkah saat ini
                  if (_currentStep == 0)
                    ElevatedButton.icon(
                      onPressed: _isProcessing ? null : _pickReferenceImage,
                      icon: const Icon(Icons.photo_library),
                      label: const Text('1. Pilih Gambar Referensi'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                      ),
                    ),
                  if (_currentStep == 1)
                    ElevatedButton.icon(
                      onPressed: _isProcessing || !_isCameraActive
                          ? null
                          : _takePicture,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('2. Ambil Gambar'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                      ),
                    ),
                  if (_currentStep == 2 && _verificationResult == null)
                    ElevatedButton.icon(
                      onPressed: _isProcessing ? null : () => _verifyFaces(),
                      icon: const Icon(Icons.compare),
                      label: const Text('3. Verifikasi Wajah'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                      ),
                    ),
                  const SizedBox(height: 16),

                  // Tombol utilitas
                  Row(
                    children: [
                      if (_currentStep >= 1)
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing
                                ? null
                                : () {
                                    setState(() {
                                      if (_currentStep == 2) {
                                        _capturedImage = null;
                                        _verificationResult = null;
                                        _isCameraActive = true;
                                        _currentStep = 1;
                                      } else if (_currentStep == 1) {
                                        _referenceImage = null;
                                        _currentStep = 0;
                                        _isCameraActive = false;
                                      }
                                    });
                                  },
                            icon: const Icon(Icons.arrow_back),
                            label: const Text('Kembali'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.grey,
                            ),
                          ),
                        ),
                      if (_currentStep >= 1) const SizedBox(width: 8),
                      if (_currentStep == 1)
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing ? null : _switchCamera,
                            icon: const Icon(Icons.flip_camera_android),
                            label: const Text('Ganti Kamera'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueGrey,
                            ),
                          ),
                        ),
                      if (_verificationResult != null &&
                          !_verificationResult!['isMatch'])
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing ? null : _retakePicture,
                            icon: const Icon(Icons.replay),
                            label: const Text('Coba Lagi'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _resetProcess,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reset Semua'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
