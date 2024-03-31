import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:ionicons/ionicons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:touchable/touchable.dart';
import 'package:gallery_saver/gallery_saver.dart';
import 'package:oktoast/oktoast.dart';

late List<CameraDescription> cameras;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return OKToast(
      textPadding: EdgeInsets.all(10.0),
      child: MaterialApp(
        title: 'Object Detection',
        theme: ThemeData(
          primarySwatch: Colors.blue,
          scaffoldBackgroundColor: Colors.white,
          appBarTheme: AppBarTheme(
            color: Colors.blue,
            elevation: 0,
            centerTitle: true,
          ),
          textTheme: TextTheme(
            headline6: TextStyle(
              color: Colors.black,
              fontSize: 20.0,
              fontWeight: FontWeight.bold,
            ),
            bodyText1: TextStyle(
              color: Colors.black,
              fontSize: 16.0,
            ),
          ),
        ),
        home: SmartZoom(),
      ),
    );
  }
}

class SmartZoom extends StatefulWidget {
  SmartZoom({Key? key}) : super(key: key);

  @override
  _SmartZoomState createState() {
    return _SmartZoomState();
  }
}

class _SmartZoomState extends State<SmartZoom> {
  dynamic controller;
  dynamic objectDetector;
  dynamic _detectedObjects;
  double? maxZoomLevel;
  CameraImage? img;
  bool isPaused = false;
  bool isBusy = false;
  bool isStreamStopped = true;
  List<Widget> stackChildren = [];
  bool isZoomedOut = true;

  Future<String> _getModel(String assetPath) async {
    if (Platform.isAndroid) {
      return 'flutter_assets/$assetPath';
    }
    final path = '${(await getApplicationSupportDirectory()).path}/$assetPath';
    await Directory(dirname(path)).create(recursive: true);
    final file = File(path);
    if (!await file.exists()) {
      final byteData = await rootBundle.load(assetPath);
      await file.writeAsBytes(byteData.buffer
          .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
    }
    return file.path;
  }

  @override
  void initState() {
    super.initState();
    initModel();
    initCamera();
  }

  initModel() async {
    final modelPath = await _getModel('assets/ml/model.tflite');
    final options = LocalObjectDetectorOptions(
        modelPath: modelPath,
        classifyObjects: false,
        multipleObjects: true,
        mode: DetectionMode.stream,
        confidenceThreshold: 0.5);
    objectDetector = ObjectDetector(options: options);
  }

  initCamera() async {
    controller = CameraController(cameras[0], ResolutionPreset.high);
    await controller.initialize().then((_) async {
      maxZoomLevel = await controller.getMaxZoomLevel();
      await startStream();
      if (!mounted) {
        return;
      }
    }).catchError((Object e) {
      if (e is CameraException) {
        switch (e.code) {
          case 'CameraAccessDenied':
            print('Camera access denied!');
            break;
          default:
            print('Camera initalization error!');
            break;
        }
      }
    });
  }

  startStream() async {
    if (isStreamStopped == true) {
      await controller.startImageStream((image) async {
        if (!isBusy) {
          isBusy = true;
          isStreamStopped = false;
          img = image;
          await performDetectionOnFrame();
        }
      });
    }
  }

  stopStream() async {
    await controller.stopImageStream();
  }

  performDetectionOnFrame() async {
    InputImage frameImg = getInputImage();
    List<DetectedObject> objects = await objectDetector.processImage(frameImg);
    double zoomLevel = await controller.getMaxZoomLevel();
    setState(() {
      _detectedObjects = objects;
    });
    isBusy = false;
  }

  InputImage getInputImage() {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in img!.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();
    final Size imageSize = Size(img!.width.toDouble(), img!.height.toDouble());
    final camera = cameras[0];

    final planeData = img!.planes.map(
      (Plane plane) {
        return InputImagePlaneMetadata(
          bytesPerRow: plane.bytesPerRow,
          height: plane.height,
          width: plane.width,
        );
      },
    ).toList();

    final inputImageData = InputImageData(
      size: imageSize,
      imageRotation:
          InputImageRotationValue.fromRawValue(camera.sensorOrientation)!,
      inputImageFormat: InputImageFormatValue.fromRawValue(img!.format.raw)!,
      planeData: planeData,
    );

    final inputImage =
        InputImage.fromBytes(bytes: bytes, inputImageData: inputImageData);

    return inputImage;
  }

  Widget drawRectangleOverObjects() {
    if (_detectedObjects == null ||
        controller == null ||
        !controller.value.isInitialized) {
      return Container(
          child: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('Loading...',
            style: TextStyle(
              color: Colors.grey,
              fontSize: 20.0,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 10.0),
          SpinKitRotatingCircle(
            color: Colors.grey,
            size: 30.0,
          )
        ]),
      ));
    }

    final Size imageSize = Size(
      controller.value.previewSize!.height,
      controller.value.previewSize!.width,
    );
    return CanvasTouchDetector(
      gesturesToOverride: [GestureType.onTapDown],
      builder: (context) => CustomPaint(
        painter: ObjectPainter(
            context, controller, maxZoomLevel!, imageSize, _detectedObjects, setState),
      ),
    );
  }

  @override
  void dispose() {
    controller?.dispose();
    objectDetector?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Size size = MediaQuery.of(context).size;
    if (controller != null) {
      stackChildren.add(
        Positioned(
          top: 0.0,
          left: 0.0,
          width: size.width,
          height: size.height,
          child: Container(
            child: (controller.value.isInitialized)
                ? AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: CameraPreview(controller),
                  )
                : Container(),
          ),
        ),
      );
      if (isPaused == false) {
        stackChildren.add(
          Positioned(
            top: 0.0,
            left: 0.0,
            width: size.width,
            height: size.height,
            child: drawRectangleOverObjects(),
          ),
        );
      }
    }

    return Scaffold(
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (!isZoomedOut)
            FloatingActionButton(
              onPressed: () async {
                controller.setZoomLevel(await controller.getMinZoomLevel());
                setState(() {
                  isZoomedOut = true;
                });
              },
              child: Icon(Icons.zoom_out),
            ),
          FloatingActionButton(
            onPressed: () async {
              if (isStreamStopped == false) {
                await stopStream();
                setState(() {
                  isStreamStopped = true;
                });
                await controller.lockCaptureOrientation();
                final image = await controller.takePicture();
                if (image != null) {
                  final fileName = basename(image.path);
                  final filePath = await getApplicationDocumentsDirectory();
                  await image.saveTo('${filePath.path}/$fileName');
                  GallerySaver.saveImage(image.path).then((success) {
                    if (success = true) {
                      showToast('Picture captured and saved!',
                        backgroundColor: Colors.green,
                      );
                    } else {
                      showToast('Picture couldn\'t be saved!',
                        backgroundColor: Colors.red,
                      );
                    }
                  });
                  await startStream();
                }
              } else {
                showToast('Camera is loading!',
                  backgroundColor: Colors.yellow,
                );
              }
            },
            child: Icon(Ionicons.camera_outline),
          ),
        ],
      ),
      appBar: AppBar(
        title: const Text('Smart Object Zoom Camera'),
      ),
      body: (controller == null)
          ? Container(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Loading...',
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 20.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 10.0),
                    SpinKitRotatingCircle(
                      color: Colors.grey,
                      size: 30.0,
                    ),
                  ],
                ),
              ),
            )
          : Stack(
              children: stackChildren,
            ),
    );
  }
}

class ObjectPainter extends CustomPainter {
  ObjectPainter(this.context, this.controller, this.maxZoomLevel, this.imgSize,
      this.objects, this.setState);

  final BuildContext context;
  final Size imgSize;
  final List<DetectedObject> objects;
  final double maxZoomLevel;
  CameraController controller;
  bool isZoomedOut = true;
  final void Function(VoidCallback fn) setState;

  @override
  void paint(Canvas canvas, Size size) {
    TouchyCanvas touchyCanvas = TouchyCanvas(context, canvas);
    final double scaleX = size.width / imgSize.width;
    final double scaleY = size.height / imgSize.height;

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = Colors.red;

    for (DetectedObject detectedObject in objects) {
      touchyCanvas.drawRect(
        Rect.fromLTRB(
          detectedObject.boundingBox.left * scaleX,
          detectedObject.boundingBox.top * scaleY,
          detectedObject.boundingBox.right * scaleX,
          detectedObject.boundingBox.bottom * scaleY,
        ),
        paint,
        onTapDown: (tapDetail) async {
          final double zoomScaleX =
              size.width / detectedObject.boundingBox.width;
          final double zoomScaleY =
              size.height / detectedObject.boundingBox.height;
          double zoomLevel = maxZoomLevel;
          if (zoomScaleX > zoomScaleY) {
            if (zoomScaleX < maxZoomLevel) {
              zoomLevel = zoomScaleX;
            }
          } else {
            if (zoomScaleY < maxZoomLevel) {
              zoomLevel = zoomScaleY;
            }
          }
          controller.setZoomLevel(zoomLevel);
          if (zoomLevel > await controller.getMinZoomLevel()) {
            setState(() {
              isZoomedOut = false;
            });
          } else {
            setState(() {
              isZoomedOut = true;
            });
          }
        },
      );
    }
  }

  @override
  bool shouldRepaint(ObjectPainter oldDelegate) {
    return oldDelegate.imgSize != imgSize || oldDelegate.objects != objects;
  }
}
