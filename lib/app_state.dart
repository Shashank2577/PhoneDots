import 'package:flutter/material.dart';

import 'agent/agent.dart';
import 'app_services.dart';

/// App-wide UI state: the active chat and tab.
class AppState extends ChangeNotifier {
  AppState(this.services) : chat = ChatController(services) {
    services.savedArrived.addListener(_showSaved);
  }

  static const savedTab = 1;
  static const modelsTab = 3;

  void _showSaved() {
    if (services.savedArrived.value == null) return;
    goTo(savedTab);
  }

  final AppServices services;
  ChatController chat;
  int tab = 0;

  void goTo(int index) {
    tab = index;
    notifyListeners();
  }

  void newChat() {
    if (chat.messages.isEmpty) return;
    chat.dispose();
    chat = ChatController(services);
    notifyListeners();
  }

  Future<void> open(String id) async {
    final c = await services.conversations.open(id);
    if (c == null) return;
    chat.dispose();
    chat = ChatController(services, conversation: c);
    tab = 0;
    notifyListeners();
  }

  /// Switches to chat and hands it something to do.
  void startChat(Future<void> Function(ChatController chat) action) {
    newChat();
    tab = 0;
    notifyListeners();
    action(chat);
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppServices services(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!.services;
}
