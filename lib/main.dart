import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'presentation/today_screen.dart';

void main() {
  runApp(const ProviderScope(child: TamidApp()));
}

class TamidApp extends StatelessWidget {

  const TamidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tamid',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const TodayScreen(),
    );
  }
}
