import 'package:flutter/material.dart';

/// Roles the server can assign. Only [patient] can be created from the app;
/// every other account is issued by an administrator.
enum UserRole { patient, doctor, nurse, staff, admin }

extension UserRoleDetails on UserRole {
  String get label => switch (this) {
    UserRole.patient => 'Patient',
    UserRole.doctor => 'Doctor',
    UserRole.nurse => 'Nurse',
    UserRole.staff => 'Reception',
    UserRole.admin => 'Administrator',
  };

  IconData get icon => switch (this) {
    UserRole.patient => Icons.person_outline_rounded,
    UserRole.doctor => Icons.medical_services_outlined,
    UserRole.nurse => Icons.monitor_heart_outlined,
    UserRole.staff => Icons.support_agent_rounded,
    UserRole.admin => Icons.admin_panel_settings_outlined,
  };

  static UserRole fromServer(String? value) => UserRole.values.firstWhere(
    (r) => r.name == value,
    orElse: () => UserRole.patient,
  );
}
