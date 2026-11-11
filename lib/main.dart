import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const RoverControlApp());
}

enum BtConnectionState {
  disconnected,
  connecting,
  connected,
}

class RoverControlApp extends StatelessWidget {
  const RoverControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HC-05 Rover Controller',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF090D16),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF22D3EE),
          secondary: Color(0xFF06B6D4),
          surface: Color(0xFF111827),
          error: Color(0xFFEF4444),
        ),
        useMaterial3: true,
      ),
      home: const RoverDashboardScreen(),
    );
  }
}

class RoverDashboardScreen extends StatefulWidget {
  const RoverDashboardScreen({super.key});

  @override
  State<RoverDashboardScreen> createState() => _RoverDashboardScreenState();
}

class _RoverDashboardScreenState extends State<RoverDashboardScreen>
    with TickerProviderStateMixin {
  final FlutterBluetoothSerial _bluetooth = FlutterBluetoothSerial.instance;
  final SpeechToText _speechToText = SpeechToText();

  BluetoothConnection? _connection;
  BluetoothDevice? _connectedDevice;
  BtConnectionState _btState = BtConnectionState.disconnected;

  StreamSubscription<Uint8List>? _inputSubscription;
  StreamSubscription<BluetoothState>? _btAdapterSubscription;

  bool _speechAvailable = false;
  bool _isListening = false;
  String _recognizedWords = 'Tap the microphone and speak a command...';
  String _lastCommandSymbol = '--';
  String _activeDirection = '';

  late final AnimationController _connectingPulseController;
  late final AnimationController _micPulseController;

  @override
  void initState() {
    super.initState();

    _connectingPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _micPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );

    _listenBluetoothAdapterState();
    _initSpeechToText();
  }

  @override
  void dispose() {
    _connectingPulseController.dispose();
    _micPulseController.dispose();
    _inputSubscription?.cancel();
    _btAdapterSubscription?.cancel();
    _connection?.dispose();
    _speechToText.stop();
    super.dispose();
  }

  void _listenBluetoothAdapterState() {
    _btAdapterSubscription = _bluetooth.onStateChanged().listen((state) {
      if (state == BluetoothState.STATE_OFF && mounted) {
        _handleForcedDisconnect('Bluetooth was turned off.');
      }
    });
  }

  Future<void> _initSpeechToText() async {
    try {
      final available = await _speechToText.initialize(
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'done' || status == 'notListening') {
            setState(() => _isListening = false);
            _micPulseController.stop();
            _micPulseController.reset();
          }
        },
        onError: (error) {
          if (!mounted) return;
          setState(() => _isListening = false);
          _micPulseController.stop();
          _micPulseController.reset();
          _showAlert('Voice error: ${error.errorMsg}', isError: true);
        },
      );
      if (mounted) {
        setState(() => _speechAvailable = available);
      }
    } catch (e) {
      if (mounted) {
        _showAlert('Speech recognition unavailable: $e', isError: true);
      }
    }
  }

  Future<bool> _ensureBluetoothPermissions() async {
    final statuses = await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.locationWhenInUse,
    ].request();

    final denied = statuses.values.any((s) => s.isDenied || s.isPermanentlyDenied);
    if (denied) {
      _showAlert(
        'Bluetooth permissions are required to scan and connect to HC-05.',
        isError: true,
      );
      return false;
    }
    return true;
  }

  Future<void> _openDevicePicker() async {
    final hasPerms = await _ensureBluetoothPermissions();
    if (!hasPerms) return;

    final isEnabled = await _bluetooth.isEnabled ?? false;
    if (!isEnabled) {
      final enabledNow = await _bluetooth.requestEnable() ?? false;
      if (!enabledNow) {
        _showAlert('Bluetooth is turned off. Please enable Bluetooth.', isError: true);
        return;
      }
    }

    List<BluetoothDevice> bondedDevices = [];
    try {
      bondedDevices = await _bluetooth.getBondedDevices();
    } catch (e) {
      _showAlert('Failed to fetch paired devices: $e', isError: true);
      return;
    }

    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF1E293B)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Select Paired HC-05 Device',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFF8FAFC),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: Color(0xFF94A3B8)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (bondedDevices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: Text(
                        'No paired Bluetooth devices found.\nPair your HC-05 in Android Settings first (PIN: 1234 or 0000).',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF94A3B8), height: 1.5),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: bondedDevices.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: Color(0xFF1E293B), height: 1),
                      itemBuilder: (context, index) {
                        final device = bondedDevices[index];
                        final isHc05 = (device.name ?? '').toUpperCase().contains('HC-05');
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          leading: Icon(
                            Icons.bluetooth,
                            color: isHc05 ? const Color(0xFF22D3EE) : const Color(0xFF94A3B8),
                          ),
                          title: Text(
                            device.name ?? 'Unknown Device',
                            style: const TextStyle(
                              color: Color(0xFFF1F5F9),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            device.address,
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                          trailing: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF0891B2),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () {
                              Navigator.pop(context);
                              _connectToDevice(device);
                            },
                            child: const Text('Pair'),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    await _disconnect(silent: true);

    setState(() {
      _btState = BtConnectionState.connecting;
      _connectedDevice = device;
    });
    _connectingPulseController.repeat(reverse: true);

    try {
      final connection = await BluetoothConnection.toAddress(device.address);
      if (!mounted) {
        connection.dispose();
        return;
      }

      _connection = connection;
      _connectingPulseController.stop();
      _connectingPulseController.reset();

      setState(() {
        _btState = BtConnectionState.connected;
      });

      _showAlert('Connected to ${device.name ?? device.address}');

      _inputSubscription = connection.input?.listen(
        (Uint8List data) {
          // Incoming telemetry from Arduino can be processed here if needed.
        },
        onDone: () {
          if (mounted && _btState == BtConnectionState.connected) {
            _handleForcedDisconnect('Bluetooth connection dropped.');
          }
        },
        onError: (Object error) {
          if (mounted) {
            _handleForcedDisconnect('Socket error: $error');
          }
        },
      );
    } catch (e) {
      _connectingPulseController.stop();
      _connectingPulseController.reset();
      if (mounted) {
        setState(() {
          _btState = BtConnectionState.disconnected;
          _connectedDevice = null;
        });
        _showAlert('Could not connect to ${device.name ?? device.address}: $e', isError: true);
      }
    }
  }

  Future<void> _disconnect({bool silent = false}) async {
    if (_btState == BtConnectionState.connected) {
      _sendCommand('S', showOfflineAlert: false);
    }
    await _inputSubscription?.cancel();
    _inputSubscription = null;
    await _connection?.close();
    _connection?.dispose();
    _connection = null;

    _connectingPulseController.stop();
    _connectingPulseController.reset();

    if (mounted) {
      setState(() {
        _btState = BtConnectionState.disconnected;
        _connectedDevice = null;
        _activeDirection = '';
      });
      if (!silent) {
        _showAlert('Disconnected from HC-05.');
      }
    }
  }

  void _handleForcedDisconnect(String reason) {
    _inputSubscription?.cancel();
    _inputSubscription = null;
    _connection?.dispose();
    _connection = null;
    _connectingPulseController.stop();
    _connectingPulseController.reset();

    setState(() {
      _btState = BtConnectionState.disconnected;
      _connectedDevice = null;
      _activeDirection = '';
    });
    _showAlert(reason, isError: true);
  }

  void _sendCommand(String char, {bool showOfflineAlert = true}) {
    setState(() => _lastCommandSymbol = char);

    if (_connection == null || !_connection!.isConnected) {
      if (showOfflineAlert) {
        _showAlert('Not connected to HC-05. Connect a device first.', isError: true);
      }
      return;
    }

    try {
      _connection!.output.add(Uint8List.fromList(utf8.encode(char)));
      _connection!.output.allSent;
    } catch (e) {
      _handleForcedDisconnect('Failed to transmit command: $e');
    }
  }

  Future<void> _toggleListening() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _showAlert('Microphone permission is required for voice control.', isError: true);
      return;
    }

    if (!_speechAvailable) {
      await _initSpeechToText();
      if (!_speechAvailable) {
        _showAlert('Speech recognition is not available on this device.', isError: true);
        return;
      }
    }

    if (_isListening) {
      await _speechToText.stop();
      setState(() => _isListening = false);
      _micPulseController.stop();
      _micPulseController.reset();
    } else {
      setState(() {
        _isListening = true;
        _recognizedWords = 'Listening...';
      });
      _micPulseController.repeat(reverse: true);

      await _speechToText.listen(
        onResult: _onSpeechResult,
        listenFor: const Duration(seconds: 12),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(partialResults: true),
      );
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    final transcript = result.recognizedWords.trim();
    if (transcript.isEmpty) return;

    setState(() {
      _recognizedWords = transcript;
    });

    final mapped = _mapVoiceToSymbol(transcript.toLowerCase());
    if (mapped != null) {
      _sendCommand(mapped);
    }
  }

  String? _mapVoiceToSymbol(String phrase) {
    if (phrase.contains('forward') ||
        phrase.contains('go') ||
        phrase.contains('straight')) {
      return '^';
    }
    if (phrase.contains('backward') ||
        phrase.contains('back') ||
        phrase.contains('reverse')) {
      return '-';
    }
    if (phrase.contains('turn left') || phrase.contains('left')) {
      return '<';
    }
    if (phrase.contains('turn right') || phrase.contains('right')) {
      return '>';
    }
    if (phrase.contains('stop') ||
        phrase.contains('halt') ||
        phrase.contains('wait')) {
      return '*';
    }
    return null;
  }

  void _showAlert(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
          ),
          backgroundColor: isError ? const Color(0xFFB91C1C) : const Color(0xFF0E7490),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1320),
        elevation: 0,
        title: const Text(
          'HC-05 Rover Console',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: Color(0xFFF8FAFC),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _btState == BtConnectionState.connected
                ? OutlinedButton.icon(
                    onPressed: _disconnect,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFF87171),
                      side: const BorderSide(color: Color(0xFF7F1D1D)),
                    ),
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text('Disconnect'),
                  )
                : FilledButton.icon(
                    onPressed: _btState == BtConnectionState.connecting
                        ? null
                        : _openDevicePicker,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0891B2),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.bluetooth_searching, size: 18),
                    label: const Text('Connect'),
                  ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildBluetoothStatusBanner(),
              const SizedBox(height: 24),
              _buildDpadPanel(),
              const SizedBox(height: 24),
              _buildVoiceControlCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBluetoothStatusBanner() {
    Color dotColor;
    Color borderColor;
    String statusText;

    switch (_btState) {
      case BtConnectionState.disconnected:
        dotColor = const Color(0xFFEF4444);
        borderColor = const Color(0xFF7F1D1D);
        statusText = 'Disconnected';
        break;
      case BtConnectionState.connecting:
        dotColor = const Color(0xFFFACC15);
        borderColor = const Color(0xFF854D0E);
        statusText = 'Connecting...';
        break;
      case BtConnectionState.connected:
        dotColor = const Color(0xFF22C55E);
        borderColor = const Color(0xFF14532D);
        final name = _connectedDevice?.name ?? _connectedDevice?.address ?? 'HC-05';
        statusText = 'Connected to $name';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          if (_btState == BtConnectionState.connecting)
            FadeTransition(
              opacity: Tween<double>(begin: 0.35, end: 1.0)
                  .animate(_connectingPulseController),
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: dotColor.withValues(alpha: 0.7), blurRadius: 10),
                  ],
                ),
              ),
            )
          else
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: dotColor.withValues(alpha: 0.75), blurRadius: 12),
                ],
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              statusText,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFFF8FAFC),
              ),
            ),
          ),
          Text(
            'TX: $_lastCommandSymbol',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF22D3EE),
            ),
          ),
