import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class FaceEmbeddingModel {
  Interpreter? _interpreter;
  List<int>? _inputShape;
  List<int>? _outputShape;
  bool _isModelLoaded = false;

  FaceEmbeddingModel() {
    _loadModel();
  }

  Future<void> ensureModelLoaded() async {
    if (!_isModelLoaded) {
      await _loadModel();
    }
  }

  Future<void> _loadModel() async {
    try {
      // Coba loads model dari assets
      _interpreter = await Interpreter.fromAsset('assets/facenet.tflite');
      _inputShape = _interpreter!.getInputTensor(0).shape;
      _outputShape = _interpreter!.getOutputTensor(0).shape;

      print("Model berhasil dimuat");
      print("Input shape: $_inputShape");
      print("Output shape: $_outputShape");

      _isModelLoaded = true;
    } catch (e) {
      print("Error saat memuat model: $e");
      rethrow;
    }
  }

  Future<Float32List> getEmbedding(File imageFile) async {
    await ensureModelLoaded();

    if (_interpreter == null || _inputShape == null || _outputShape == null) {
      throw Exception("Model belum dimuat dengan benar");
    }

    try {
      // Baca gambar
      final imageBytes = imageFile.readAsBytesSync();
      final image = img.decodeImage(imageBytes);

      if (image == null) {
        throw Exception("Tidak dapat membaca gambar");
      }

      // Mendapatkan dimensi input dari model
      final int inputWidth = _inputShape![1];
      final int inputHeight = _inputShape![2];
      final int channels = _inputShape![3];

      // Resize gambar sesuai kebutuhan model
      final processedImage = img.copyResize(
        image,
        width: inputWidth,
        height: inputHeight,
      );

      // Konversi gambar ke format yang sesuai dengan model (biasanya float32)
      Float32List inputBuffer =
          Float32List(1 * inputHeight * inputWidth * channels);

      // Preprocessing - normalisasi nilai piksel
      for (int y = 0; y < inputHeight; y++) {
        for (int x = 0; x < inputWidth; x++) {
          final pixel = processedImage.getPixel(x, y);

          // Normalisasi ke range [-1, 1]
          final r = (img.getRed(pixel) - 127.5) / 127.5;
          final g = (img.getGreen(pixel) - 127.5) / 127.5;
          final b = (img.getBlue(pixel) - 127.5) / 127.5;

          final offset = (y * inputWidth + x) * channels;
          inputBuffer[offset] = r;
          inputBuffer[offset + 1] = g;
          inputBuffer[offset + 2] = b;
        }
      }

      // Siapkan output buffer dengan bentuk yang benar
      final outputBuffer = Float32List(_outputShape!.reduce((a, b) => a * b));

      // Jalankan inferensi
      print(
          "Menjalankan inferensi dengan input shape: $_inputShape dan output shape: $_outputShape");

      // Berikan input ke interpreter
      _interpreter!.run(inputBuffer.buffer, outputBuffer.buffer);

      // Kembalikan output sebagai Float32List
      return outputBuffer;
    } catch (e) {
      print("Error saat menjalankan inferensi: $e");
      rethrow;
    }
  }
}

double cosineSimilarity(List<double> vectorA, List<double> vectorB) {
  if (vectorA.length != vectorB.length) {
    throw Exception(
        "Panjang vektor harus sama untuk menghitung cosine similarity");
  }

  double dotProduct = 0.0;
  double normA = 0.0;
  double normB = 0.0;

  for (int i = 0; i < vectorA.length; i++) {
    dotProduct += vectorA[i] * vectorB[i];
    normA += vectorA[i] * vectorA[i];
    normB += vectorB[i] * vectorB[i];
  }

  // Hindari pembagian dengan nol
  if (normA == 0 || normB == 0) {
    return 0.0;
  }

  return dotProduct / (sqrt(normA) * sqrt(normB));
}
