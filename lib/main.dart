import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() => runApp(const PavanApp());

class PavanApp extends StatelessWidget {
  const PavanApp({super.key});

  static const Color brand = Color(0xFFB3222A);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pavan Residency',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: brand, primary: brand),
        appBarTheme: const AppBarTheme(
          backgroundColor: brand,
          foregroundColor: Colors.white,
          centerTitle: true,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(backgroundColor: brand),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
