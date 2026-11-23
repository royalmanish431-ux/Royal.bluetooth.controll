import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const CarAutomationApp());
}

class CarAutomationApp extends StatelessWidget {
  const CarAutomationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Car Automation',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1120),
        primaryColor: const Color(0xFF00E5FF),
      ),
      home: const ControllerScreen(),
    );
  }
}

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  static const MethodChannel _btChannel =
      MethodChannel('com.example.hc05_rover_controller/bluetooth');

  // Always-ON obstacle sensor trigger character
  static const String _obstacleChar = 'U';

  List _devices = [];
  dynamic _selectedDevice;
  bool _isConnecting = false;
  bool _isConnected = false;

  Timer? _obstacleHeartbeatTimer;

  bool _continuousMicOn = false;
  String _voiceText = 'Tap Mic ONCE for Continuous Hands-Free Mode';
  String _lastSentCommand = 'None';
  String _debugStatus = '';

  @override
  void initState() {
    super.initState();
    _btChannel.setMethodCallHandler(_handleNativeCallbacks);
    _initPermissionsAndDevices();
  }

  @override
  void dispose() {
    _obstacleHeartbeatTimer?.cancel();
    super.dispose();
  }

  Future<dynamic> _handleNativeCallbacks(MethodCall call) async {
    if (call.method == 'onSpeechResult') {
      final String spoken = (call.arguments ?? '').toString();
      if (spoken.isNotEmpty && mounted) {
        setState(() {
          _voiceText = spoken;
        });
        _processVoiceCommand(spoken.toLowerCase());
      }
    } else if (call.method == 'onSpeechStatus') {
      final String status = (call.arguments ?? '').toString();
      if (status == 'stopped' && mounted && _continuousMicOn) {
        setState(() => _continuousMicOn = false);
      }
    } else if (call.method == 'onGamepadCommand') {
      final String cmd = (call.arguments ?? '').toString();
      if (cmd.isNotEmpty && mounted) {
        await _sendCommandWithAutoSensor(cmd);
      }
    }
  }

  Future<void> _initPermissionsAndDevices() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
      Permission.microphone,
    ].request();

    try {
      final List result = await _btChannel.invokeMethod('getBondedDevices');
      final parsed = result
          .map((item) => {
                'name': item['name']?.toString() ?? 'Unknown',
                'address': item['address']?.toString() ?? '',
              })
          .toList();

      setState(() {
        _devices = parsed;
        if (_devices.isNotEmpty) {
          _selectedDevice = _devices.firstWhere(
            (d) => d['name'].toString().toUpperCase().contains('HC-05'),
            orElse: () => _devices.first,
          );
        }
      });
    } on PlatformException catch (e) {
      _showSnack('Bluetooth Error: ${e.message}');
    }
  }

  // Always-ON 350ms sensor heartbeat — never pauses
  void _startAlwaysOnSensorHeartbeat() {
    _obstacleHeartbeatTimer?.cancel();
    _obstacleHeartbeatTimer =
        Timer.periodic(const Duration(milliseconds: 350), (_) async {
      if (_isConnected) {
        await _sendRaw(_obstacleChar, silent: true);
      }
    });
  }

  Future<void> _connectToDevice(dynamic device) async {
    if (_isConnecting) return;

    setState(() {
      _isConnecting = true;
      _debugStatus = 'Connecting to ${device['name']}...';
    });

    try {
      final bool connected = await _btChannel.invokeMethod(
        'connect',
        {'address': device['address']},
      );

      setState(() {
        _isConnected = connected;
        _isConnecting = false;
        _debugStatus = connected ? '' : 'Connection returned false';
      });

      if (connected) {
        _showSnack('Connected! Ultrasonic Sensor Always Active');
        await Future.delayed(const Duration(milliseconds: 200));
        await _sendRaw(_obstacleChar);
        _startAlwaysOnSensorHeartbeat();
      }
    } on PlatformException catch (e) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _debugStatus = 'Error: ${e.message}';
      });
      _showSnack('Failed: ${e.message}');
    }
  }

  Future<void> _disconnect() async {
    _obstacleHeartbeatTimer?.cancel();
    try {
      await _btChannel.invokeMethod('disconnect');
    } catch (_) {}
    setState(() {
      _isConnected = false;
      _debugStatus = '';
    });
  }

  Future<void> _sendRaw(String cmd, {bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _lastSentCommand = '$cmd + AUTO($_obstacleChar)';
      });
    }
    if (_isConnected) {
      try {
        await _btChannel.invokeMethod('send', {'data': cmd});
      } on PlatformException catch (e) {
        _obstacleHeartbeatTimer?.cancel();
        if (mounted) setState(() => _isConnected = false);
        _showSnack('Disconnected: ${e.message}');
      }
    } else if (!silent) {
      _showSnack('Not connected to HC-05!');
    }
  }

  // Sends manual/voice command and immediately keeps sensor ('U') active
  Future<void> _sendCommandWithAutoSensor(String cmd) async {
    await _sendRaw(cmd);
    if (_isConnected) {
      await Future.delayed(const Duration(milliseconds: 80));
      await _sendRaw(_obstacleChar, silent: true);
    }
  }

  Future<void> _toggleContinuousMic() async {
    if (!_continuousMicOn) {
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        _showSnack('Microphone permission required!');
        return;
      }
      try {
        await _btChannel.invokeMethod('startContinuousVoice');
        setState(() {
          _continuousMicOn = true;
          _voiceText = 'Continuous Listening ON... Speak commands';
        });
      } on PlatformException catch (e) {
        _showSnack('Voice Error: ${e.message}');
      }
    } else {
      try {
        await _btChannel.invokeMethod('stopContinuousVoice');
      } catch (_) {}
      setState(() {
        _continuousMicOn = false;
        _voiceText = 'Continuous Listening OFF';
      });
    }
  }

  void _processVoiceCommand(String words) {
    if (words.contains('forward') ||
        words.contains('go') ||
        words.contains('straight') ||
        words.contains('aage')) {
      _sendCommandWithAutoSensor('^');
    } else if (words.contains('back') ||
        words.contains('reverse') ||
        words.contains('peeche')) {
      _sendCommandWithAutoSensor('-');
    } else if (words.contains('left') || words.contains('baye')) {
      _sendCommandWithAutoSensor('<');
    } else if (words.contains('right') || words.contains('daye')) {
      _sendCommandWithAutoSensor('>');
    } else if (words.contains('stop') ||
        words.contains('halt') ||
        words.contains('ruk')) {
      _sendCommandWithAutoSensor('*');
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Widget _buildStatusSign() {
    Color dotColor = Colors.redAccent;
    String statusText = 'Disconnected';

    if (_isConnecting) {
      dotColor = Colors.amber;
      statusText = 'Connecting...';
    } else if (_isConnected) {
      dotColor = const Color(0xFF00E676);
      statusText = 'Connected: ${_selectedDevice?['name'] ?? "HC-05"}';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: dotColor.withOpacity(0.6), width: 1.5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: dotColor.withOpacity(0.8),
                      blurRadius: 10,
                      spreadRadius: 2,
                    )
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.bluetooth, color: dotColor, size: 22),
              const SizedBox(width: 8),
              Text(
                statusText,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ],
          ),
          if (_isConnected)
            IconButton(
              icon: const Icon(Icons.link_off, color: Colors.redAccent),
              onPressed: _disconnect,
              tooltip: 'Disconnect',
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh, color: Color(0xFF00E5FF)),
              onPressed: _initPermissionsAndDevices,
              tooltip: 'Refresh Devices',
            ),
        ],
      ),
    );
  }

  Widget _buildControlBtn(IconData icon, String label, String cmd,
      {Color color = const Color(0xFF1E293B)}) {
    return GestureDetector(
      onTapDown: (_) => _sendCommandWithAutoSensor(cmd),
      onTapUp: (_) {
        if (cmd != 'S') _sendCommandWithAutoSensor('S');
      },
      onTapCancel: () {
        if (cmd != 'S') _sendCommandWithAutoSensor('S');
      },
      child: Container(
        width: 82,
        height: 82,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 8,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 34, color: Colors.white),
            const SizedBox(height: 4),
            Text(label,
                style:
                    const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'CAR AUTOMATION',
              style: TextStyle(
                letterSpacing: 1.5,
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
            SizedBox(height: 3),
            Text(
              'Design By Manish Royal',
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w500,
                color: Color(0xFF00E5FF),
              ),
            ),
          ],
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _buildStatusSign(),
            const SizedBox(height: 12),

            if (!_isConnected)
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          hint: const Text('Select HC-05'),
                          value: _selectedDevice?['address'],
                          items: _devices.map<DropdownMenuItem<String>>((device) {
                            return DropdownMenuItem<String>(
                              value: device['address'],
                              child: Text(
                                '${device['name']} (${device['address']})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (addr) {
                            if (addr != null) {
                              setState(() {
                                _selectedDevice = _devices.firstWhere(
                                    (d) => d['address'] == addr);
                              });
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: (_selectedDevice != null && !_isConnecting)
                        ? () => _connectToDevice(_selectedDevice)
                        : null,
                    child: Text(
                      _isConnecting ? 'WAIT...' : 'CONNECT',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),

            if (_debugStatus.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6.0),
                child: Text(
                  _debugStatus,
                  style: const TextStyle(color: Colors.amber, fontSize: 12),
                ),
              ),

            const Spacer(),

            Column(
              children: [
                _buildControlBtn(Icons.keyboard_arrow_up, 'FORWARD', 'F'),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildControlBtn(Icons.keyboard_arrow_left, 'LEFT', 'L'),
                    const SizedBox(width: 14),
                    _buildControlBtn(Icons.stop_circle_outlined, 'STOP', 'S',
                        color: Colors.redAccent.withOpacity(0.8)),
                    const SizedBox(width: 14),
                    _buildControlBtn(Icons.keyboard_arrow_right, 'RIGHT', 'R'),
                  ],
                ),
                const SizedBox(height: 14),
                _buildControlBtn(Icons.keyboard_arrow_down, 'BACKWARD', 'B'),
              ],
            ),

            const Spacer(),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: _continuousMicOn
                      ? Colors.redAccent
                      : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    _voiceText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 14, color: Color(0xFF94A3B8)),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Last Sent Signal: $_lastSentCommand',
                    style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF00E5FF),
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: _toggleContinuousMic,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _continuousMicOn
                            ? Colors.redAccent
                            : const Color(0xFF00E5FF),
                        boxShadow: [
                          BoxShadow(
                            color: (_continuousMicOn
                                    ? Colors.redAccent
                                    : const Color(0xFF00E5FF))
                                .withOpacity(0.6),
                            blurRadius: 16,
                            spreadRadius: 3,
                          )
                        ],
                      ),
                      child: Icon(
                        _continuousMicOn ? Icons.mic : Icons.mic_none,
                        size: 30,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _continuousMicOn
                        ? 'LIVE MIC ON (Tap to Stop)'
                        : 'TAP TO START CONTINUOUS MIC',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _continuousMicOn
                          ? Colors.redAccent
                          : const Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
