import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/auth_screen.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const HospitalQueueApp());
}

class HospitalQueueApp extends StatelessWidget {
  const HospitalQueueApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'QueueCare',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    // The email-confirmation page opens queuecare://auth/signin; whatever route
    // arrives, the user lands on the sign-in screen. There is no role picker:
    // the server decides which dashboard an account sees.
    home: const AuthScreen(),
    onGenerateRoute: (settings) => null,
    onUnknownRoute: (settings) =>
        MaterialPageRoute<void>(builder: (_) => const AuthScreen()),
  );
}
