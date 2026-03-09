
import 'package:flutter/material.dart';
import 'package:media_store_plus/media_store_plus.dart';

// Import the mobile scanner
import 'mobile_scanner.dart';

void main() async{
  WidgetsFlutterBinding.ensureInitialized();
  await MediaStore.ensureInitialized();
  MediaStore.appFolder = "TXQR_Files";
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TXQR Scanner',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MobileQRScannerScreen(),
    );
  }
}