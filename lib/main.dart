import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'HomeScreen.dart';

Future<void> main() async {
  await dotenv.load();
  runApp(const MaterialApp(home:HomeScreen()));
}


