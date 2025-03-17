import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:permission_handler/permission_handler.dart'
    as permissionHandler;
import 'package:image/image.dart' as img;
import 'ml.dart'; // Import the ml.dart file

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Dapatkan daftar kamera yang tersedia
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

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

  // Fungsi utama untuk verifikasi wajah
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
      // Gunakan await untuk menunggu hasil dari fungsi asynchronous
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
    setState(() {
      _verificationResult = null;
      _capturedImage = null;
    });
  }

  // Helper untuk menampilkan snackbar
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.file(
                                    _referenceImage!,
                                    fit: BoxFit.cover,
                                  ),
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
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.file(
                                    _capturedImage!,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: FutureBuilder<void>(
                                    future: _initializeControllerFuture,
                                    builder: (context, snapshot) {
                                      if (snapshot.connectionState ==
                                          ConnectionState.done) {
                                        return CameraPreview(_cameraController);
                                      } else {
                                        return const Center(
                                            child: CircularProgressIndicator());
                                      }
                                    },
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
                      Text(
                        _verificationResult!['message'],
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _verificationResult!['isMatch']
                              ? Colors.green.shade900
                              : Colors.red.shade900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Similarity: ${(_verificationResult!['similarity'] * 100).toStringAsFixed(2)}%',
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
                  ElevatedButton(
                    onPressed: _isProcessing ? null : _pickReferenceImage,
                    child: const Text('Pilih Gambar Referensi'),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed:
                        _isProcessing || !_isCameraActive ? null : _takePicture,
                    child: const Text('Ambil Gambar'),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: _isProcessing ? null : _switchCamera,
                    child: const Text('Ganti Kamera'),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: _isProcessing ? null : _resetProcess,
                    child: const Text('Reset'),
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
