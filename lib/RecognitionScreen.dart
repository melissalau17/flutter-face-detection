import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';


class RecognitionScreen extends StatefulWidget {
  const RecognitionScreen({Key? key}) : super(key: key);

  @override
  State<RecognitionScreen> createState() => _RecognitionScreenState();
}

class _RecognitionScreenState extends State<RecognitionScreen> {
  late ImagePicker imagePicker;
  late FaceDetector faceDetector;
  File? _image;
  late CameraController _cameraController;
  bool _isCameraInitialized = false;
  Timer? _frameTimer;

  @override
  void initState() {
    super.initState();
    imagePicker = ImagePicker();
    _initializeCamera();

    final options = FaceDetectorOptions(
        enableClassification: true,
        performanceMode: FaceDetectorMode.accurate
    );
    faceDetector = FaceDetector(options: options);
  }

  Future<void> _imgFromCamera() async {
    XFile? pickedFile = await imagePicker.pickImage(source: ImageSource.camera);
    if (pickedFile != null) {
      setState(() => _image = File(pickedFile.path));
      await doFaceDetection();
    }
  }

  Future<void> _imgFromGallery() async {
    XFile? pickedFile = await imagePicker.pickImage(
      source: ImageSource.gallery,
    );
    if (pickedFile != null) {
      setState(() => _image = File(pickedFile.path));
      await doFaceDetection();
    }
  }

  Future<void> _startWebcamStream() async {
    final apiUrl = dotenv.env['API_URL'];
    if (apiUrl == null) {
      _showResultDialog("Error", "API_URL not found in .env");
      return;
    }

    final url = Uri.parse("$apiUrl/start_stream");

    try {
      final response = await http.post(url);
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        _showResultDialog("Webcam Stream", res['message'] ?? "Streaming started.");
      } else {
        _showResultDialog("Error", "Failed to start stream (${response.statusCode})");
      }
    } catch (e) {
      _showResultDialog("Error", "Could not connect to backend.\n$e");
    }
  }

  Future<void> _stopWebcamStream() async {
    _frameTimer?.cancel();
    await _cameraController.dispose();
    setState(() => _isCameraInitialized = false);
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController.initialize();

      if (!mounted) return;
      setState(() => _isCameraInitialized = true);

      await _startWebcamStream();

      // Capture a frame every second
      _frameTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!_cameraController.value.isInitialized) return;
        try {
          final picture = await _cameraController.takePicture();
          await _sendToBackend(File(picture.path));
        } catch (e) {
          debugPrint("Frame capture error: $e");
        }
      });
    } catch (e) {
      debugPrint("Camera init failed: $e");
      _showResultDialog("Camera Error", "Could not initialize webcam.");
    }
  }

  Future<void> _sendToBackend(File imageFile) async {
    final apiUrl = dotenv.env['API_URL'];
    if (apiUrl == null) {
      _showResultDialog("Configuration Error", "API_URL not found in .env");
      return;
    }

    final cleanUrl = apiUrl.endsWith('/')
        ? apiUrl.substring(0, apiUrl.length - 1)
        : apiUrl;
    final url = Uri.parse("$cleanUrl/main");

    try {
      final bytes = await imageFile.readAsBytes();
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/octet-stream',
        },
        body: bytes
      );

      if (response.statusCode == 200) {
        final res = response.body;
        debugPrint('Backend response: $res');
        _showResultDialog("Recognition Successful", res);
      } else {
        debugPrint('Error: ${response.statusCode}');
        _showResultDialog("Error", "Backend returned ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Backend request failed: $e");
      _showResultDialog("Connection Error", "Failed to reach server.");
    }
  }

  Future<void> doFaceDetection() async {
    if (_image == null) {
      _showResultDialog("No Image", "Please pick or capture an image.");
      return;
    }

    try {
      _image = await removeRotation(_image!);

      final inputImage = InputImage.fromFile(_image!);
      List<Face> faces = await faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        _showResultDialog("No Face Detected", "Please try another image.");
        return;
      }

      final faceRect = faces.first.boundingBox;
      final bytes = await _image!.readAsBytes();
      final decoded = img.decodeImage(bytes);
      File imageToSend = _image!;

      if (decoded != null) {
        final x = max(0, faceRect.left.toInt());
        final y = max(0, faceRect.top.toInt());
        final w = min(faceRect.width.toInt(), decoded.width - x);
        final h = min(faceRect.height.toInt(), decoded.height - y);
        final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);

        final tempPath = "${_image!.path}_cropped.jpg";
        imageToSend = await File(tempPath).writeAsBytes(img.encodeJpg(cropped));
      }

      await _sendToBackend(imageToSend);
    } catch (e, st) {
      debugPrint("Face detection failed: $e\n$st");
      _showResultDialog("Error", "Face detection failed.");
    }
  }

  Future<File> removeRotation(File inputImage) async {
    final bytes = await inputImage.readAsBytes();
    final capturedImage = img.decodeImage(bytes);
    if (capturedImage == null) throw Exception("Could not decode image");

    final orientedImage = img.bakeOrientation(capturedImage);
    final corrected = await File(inputImage.path)
        .writeAsBytes(img.encodeJpg(orientedImage));
    return corrected;
  }

  void _showResultDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK"),
          )
        ],
      ),
    );
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _cameraController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1f4037), Color(0xFF99f2c8)],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              const Text(
                "Face Recognition",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 30),

              Container(
                width: screenWidth / 1.15,
                height: screenWidth / 1.15,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFffffff), Color(0xFFd4f7e6)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(75),
                      blurRadius: 15,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: _isCameraInitialized
                      ? AspectRatio(
                    aspectRatio: _cameraController.value.aspectRatio,
                    child: CameraPreview(_cameraController),
                  )
                      : _image != null
                      ? Image.file(_image!)
                      : Image.asset("images/logo.png", fit: BoxFit.fill),
                ),
              ),

              const SizedBox(height: 40),

              // Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _gradientButton(
                    icon: Icons.image,
                    label: "Gallery",
                    onTap: _imgFromGallery,
                    width: screenWidth * 0.4,
                  ),
                  _gradientButton(
                    icon: Icons.camera_alt,
                    label: "Camera",
                    onTap: _imgFromCamera,
                    width: screenWidth * 0.4,
                  ),
                ],
              ),

              _gradientButton(
                icon: Icons.videocam,
                label: _isCameraInitialized
                    ? "Stop Webcam Stream"
                    : "Start Webcam Stream",
                onTap: () async {
                  if (_isCameraInitialized) {
                    await _stopWebcamStream();
                  } else {
                    await _initializeCamera();
                  }
                },
                width: screenWidth * 0.85,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Reusable beautiful button
  Widget _gradientButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    double width = 150,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: 50,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: const LinearGradient(
            colors: [Color(0xFFffffff), Color(0xFFc4f1e0)],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 6,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.black87),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 16,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}