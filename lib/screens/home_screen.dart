import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import '../services/settings_service.dart';
import '../services/config_service.dart';
import '../services/playlist_parser.dart';
import '../services/epg_parser.dart';
import '../services/log_service.dart';
import '../services/logo_service.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/subscription.dart';
import '../widgets/ijk_player_widget.dart';
import '../widgets/group_list.dart';
import '../widgets/schedule_view.dart';
import '../widgets/channel_list.dart';
import '../widgets/logo_source_dialog.dart';
import 'settings_screen.dart';

// 列枚举，方便管理
enum FocusColumn { subscription, group, channel }

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ---------- 原有业务状态 ----------
  List<Channel> channels = [];
  List<String> groups = [];
  Channel? currentChannel;
  String? currentGroup;
  String? currentSubName;

  bool showChannelList = false;
  bool isScheduleMode = false;
  bool _showEpgInfo = true;
  bool isEditMode = false;
  bool _showRightMenu = false;

  double subWeight = 0.2;
  double groupWeight = 0.2;
  double channelWeight = 0.6;
  double scheduleGroupWeight = 0.25;
  double scheduleChannelWeight = 0.35;
  double scheduleWeight = 0.4;

  Offset scheduleModeButtonOffset = Offset(714.8865763346365, 7.9911295572917425);
  Offset channelListButtonOffset = Offset(-133.9163004557305, -4.6614786783854925);

  double _scheduleButtonInitTop = 0;
  double _channelButtonInitTop = 0;

  EpgProgram? _currentProgram;
  EpgProgram? _nextProgram;
  bool _isEpgUpdating = false;

  Timer? _epgInfoHideTimer;
  Timer? _epgUpdateTimer;
  Timer? _epgInfoTimer;

  Map<String, List<Channel>>? _fullGroupMap;
  bool _hasSubscriptions = false;
  bool _isUpdatingSubscription = false;
  bool isLoading = true;

  late File _layoutConfigFile;
  final LogoService _logoService = LogoService();

  Timer? _retryTimer;
  Channel? _retryChannel;
  Key? _playerKey;
  double currentSpeed = 0;

  final FocusNode _focusNode = FocusNode();
  String _digitBuffer = '';
  Timer? _digitTimer;

  VoidCallback? _epgListener;
  bool _autoLoaded = false;

  // ---------- 自定义焦点状态 ----------
  FocusColumn _focusColumn = FocusColumn.channel; // 当前焦点所在列
  int _focusRow = 0; // 当前焦点所在行（从0开始）

  // 获取各列的最大行数
  int get _subscriptionCount => Provider.of<SettingsService>(context, listen: false).subscriptions.length;
  int get _groupCount => groups.length;
  int get _channelCount => channels.length;

  // 根据当前焦点列获取对应的列表长度
  int get _currentColumnCount {
    switch (_focusColumn) {
      case FocusColumn.subscription:
        return _subscriptionCount;
      case FocusColumn.group:
        return _groupCount;
      case FocusColumn.channel:
        return _channelCount;
    }
  }

  // 确保 _focusRow 不超出当前列的范围
  void _clampFocusRow() {
    final maxRow = _currentColumnCount - 1;
    if (_focusRow > maxRow) _focusRow = maxRow.clamp(0, maxRow);
    if (_focusRow < 0) _focusRow = 0;
  }

  // 切换列时保持行尽量相同
  void _moveFocusColumn(FocusColumn newCol) {
    final oldCol = _focusColumn;
    if (oldCol == newCol) return;
    // 保存当前行
    final currentRow = _focusRow;
    // 切换到新列
    _focusColumn = newCol;
    // 尝试保持行不变，如果超出则调整
    final maxRow = _currentColumnCount - 1;
    if (currentRow <= maxRow) {
      _focusRow = currentRow;
    } else {
      _focusRow = maxRow.clamp(0, maxRow);
    }
    _clampFocusRow();
    setState(() {});
  }

  // 移动行
  void _moveFocusRow(int delta) {
    final newRow = _focusRow + delta;
    final maxRow = _currentColumnCount - 1;
    if (newRow < 0 || newRow > maxRow) return;
    _focusRow = newRow;
    setState(() {});
  }

  // 确认操作：根据当前列执行相应动作
  void _executeConfirm() {
    switch (_focusColumn) {
      case FocusColumn.subscription:
        // 获取当前选中的订阅
        final settings = Provider.of<SettingsService>(context, listen: false);
        final subs = settings.subscriptions;
        if (_focusRow < subs.length) {
          final sub = subs[_focusRow];
          _loadSubscriptionData(sub);
        }
        break;
      case FocusColumn.group:
        if (_focusRow < groups.length) {
          _switchToGroup(groups[_focusRow]);
        }
        break;
      case FocusColumn.channel:
        if (_focusRow < channels.length) {
          _switchChannel(channels[_focusRow]);
        }
        break;
    }
  }

  // 修复：原有方法中需要调用 _clampFocusRow 或更新焦点
  // 在 _switchToGroup 和 _applyGroupMap 中需要调整焦点状态，确保焦点行有效
  // 我们会在这些方法中手动设置焦点

  // ---------- 原有业务方法（略作调整） ----------
  DateTime get _beijingNow => EpgParser.beijingNow;
  String _formatTime(DateTime time) => EpgParser.formatBeijingTime(time);
  String _getDate(DateTime time) {
    final bj = EpgParser.toBeijing(time);
    return '${bj.year}-${bj.month.toString().padLeft(2, '0')}-${bj.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _initAsync();

    _epgListener = () {
      if (!mounted) return;
      _updateEpgInfo();
      if (isScheduleMode) setState(() {});
      _tryDownloadLogos();
    };
    EpgParser.epgUpdateCounter.addListener(_epgListener!);
  }

  Future<void> _initAsync() async {
    LogService.write('主页初始化');
    await _initLayoutConfigFile();
    await _loadLayoutConfig();

    final hasLogoSource = await _logoService.hasConfiguredSource();
    if (!hasLogoSource && mounted) {
      LogService.write('Logo: 首次使用，引导用户设置台标来源');
      await LogoSourceSettingDialog.show(context, isFirstTime: true);
    }

    _tryDownloadLogos();
    _initEpgScheduler();
    _startEpgInfoTimer();
    _loadEpgInBackground();

    if (mounted) setState(() => isLoading = false);
  }

  void _tryDownloadLogos() {
    if (channels.isEmpty) return;
    _logoService.hasConfiguredSource().then((hasSource) {
      if (hasSource && mounted) {
        _logoService.downloadAllLogos(channels);
      }
    });
  }

  void _loadEpgInBackground() {
    EpgParser.init().then((_) async {
      LogService.write('EPG: 后台加载完成');
      if (currentChannel != null && mounted) {
        await _updateEpgInfo();
        _showEpgInfoTemporarily();
      }
    }).catchError((e, stack) {
      LogService.writeCrashLog('EPG后台加载失败: $e', stack);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_autoLoaded && channels.isEmpty) {
      final settings = Provider.of<SettingsService>(context);
      if (settings.subscriptions.isNotEmpty) {
        _autoLoaded = true;
        final selectedSubs = settings.subscriptions.where((s) => s.selected).toList();
        if (selectedSubs.isNotEmpty) {
          _loadSubscriptionData(selectedSubs.first);
        } else {
          _loadSubscriptionData(settings.subscriptions.first);
        }
      }
    }
  }

  Future<void> _initLayoutConfigFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _layoutConfigFile = File('${dir.path}/layout_config.json');
      if (!await _layoutConfigFile.exists()) {
        await _saveLayoutConfig();
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  Future<void> _loadLayoutConfig() async {
    try {
      if (await _layoutConfigFile.exists()) {
        final content = await _layoutConfigFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        subWeight = json['subWeight']?.toDouble() ?? subWeight;
        groupWeight = json['groupWeight']?.toDouble() ?? groupWeight;
        channelWeight = json['channelWeight']?.toDouble() ?? channelWeight;
        scheduleGroupWeight = json['scheduleGroupWeight']?.toDouble() ?? scheduleGroupWeight;
        scheduleChannelWeight = json['scheduleChannelWeight']?.toDouble() ?? scheduleChannelWeight;
        scheduleWeight = json['scheduleWeight']?.toDouble() ?? scheduleWeight;
        scheduleModeButtonOffset = Offset(
          json['scheduleModeButtonDx']?.toDouble() ?? scheduleModeButtonOffset.dx,
          json['scheduleModeButtonDy']?.toDouble() ?? scheduleModeButtonOffset.dy,
        );
        channelListButtonOffset = Offset(
          json['channelListButtonDx']?.toDouble() ?? channelListButtonOffset.dx,
          json['channelListButtonDy']?.toDouble() ?? channelListButtonOffset.dy,
        );
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  Future<void> _saveLayoutConfig() async {
    try {
      final json = {
        'subWeight': subWeight,
        'groupWeight': groupWeight,
        'channelWeight': channelWeight,
        'scheduleGroupWeight': scheduleGroupWeight,
        'scheduleChannelWeight': scheduleChannelWeight,
        'scheduleWeight': scheduleWeight,
        'scheduleModeButtonDx': scheduleModeButtonOffset.dx,
        'scheduleModeButtonDy': scheduleModeButtonOffset.dy,
        'channelListButtonDx': channelListButtonOffset.dx,
        'channelButtonDy': channelListButtonOffset.dy,
      };
      await _layoutConfigFile.writeAsString(jsonEncode(json));
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  void _exitEditMode() {
    setState(() => isEditMode = false);
    _saveLayoutConfig();
  }

  @override
  void dispose() {
    _epgInfoHideTimer?.cancel();
    if (_epgListener != null) {
      EpgParser.epgUpdateCounter.removeListener(_epgListener!);
    }
    _epgUpdateTimer?.cancel();
    _epgInfoTimer?.cancel();
    _retryTimer?.cancel();
    _digitTimer?.cancel();
    _focusNode.dispose();
    _saveLayoutConfig();
    super.dispose();
  }

  void _initEpgScheduler() {
    _epgUpdateTimer = Timer.periodic(const Duration(hours: 6), (_) {
      _checkEpgUpdate();
    });
  }

  Future<void> _checkEpgUpdate() async {
    if (_isEpgUpdating) return;
    _isEpgUpdating = true;
    try {
      await EpgParser.init();
      await _updateEpgInfo();
    } catch (e) {
      LogService.write('EPG 更新检查失败: $e');
    } finally {
      _isEpgUpdating = false;
    }
  }

  Future<EpgProgram?> _getCurrentProgram(String channelName) async {
    return await EpgParser.getCurrentProgram(channelName);
  }

  Future<EpgProgram?> _getNextProgram(String channelName) async {
    return await EpgParser.getNextProgram(channelName);
  }

  Future<List<EpgProgram>> _getChannelPrograms(String channelName) async {
    return await EpgParser.getProgramsByChannelName(channelName);
  }

  Future<void> _updateEpgInfo() async {
    if (currentChannel == null) return;
    final current = await _getCurrentProgram(currentChannel!.name);
    final next = await _getNextProgram(currentChannel!.name);
    if (mounted) {
      setState(() {
        _currentProgram = current;
        _nextProgram = next;
      });
    }
  }

  void _startEpgInfoTimer() {
    _epgInfoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (currentChannel != null && mounted) {
        _updateEpgInfo();
      }
    });
  }

  void _showEpgInfoTemporarily() {
    _epgInfoHideTimer?.cancel();
    setState(() => _showEpgInfo = true);
    _epgInfoHideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showEpgInfo = false);
    });
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryChannel = currentChannel;
    if (_retryChannel == null) return;
    _retryTimer = Timer(const Duration(seconds: 5), () {
      if (currentChannel == _retryChannel && currentChannel != null) {
        setState(() => currentChannel = null);
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _retryChannel != null) {
            setState(() {
              _playerKey = UniqueKey();
              currentChannel = _retryChannel;
            });
          }
        });
      }
      _retryTimer = null;
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryChannel = null;
  }

  // 切换频道：更新 currentChannel，并调整焦点到频道列对应行
  void _switchChannel(Channel ch) {
    _cancelRetry();
    _digitBuffer = '';
    _digitTimer?.cancel();

    setState(() {
      currentChannel = ch;
      _updateEpgInfo();
      // 焦点移到频道列表的对应行
      final idx = channels.indexOf(ch);
      if (idx >= 0) {
        _focusColumn = FocusColumn.channel;
        _focusRow = idx;
      }
    });

    _showEpgInfoTemporarily();
    Provider.of<SettingsService>(context, listen: false).saveLastChannel(ch.name);
  }

  // 切换分组：更新 channels，调整焦点到分组列对应行，并将 currentChannel 设为分组中的第一个频道（但不自动播放）
  void _switchToGroup(String groupName) {
    if (_fullGroupMap == null || _fullGroupMap!.isEmpty) return;
    final groupChannels = _fullGroupMap![groupName];
    if (groupChannels == null || groupChannels.isEmpty) return;
    _cancelRetry();
    _digitBuffer = '';
    _digitTimer?.cancel();

    setState(() {
      currentGroup = groupName;
      channels = groupChannels;
      // 设置焦点到分组列该行
      final groupIdx = groups.indexOf(groupName);
      if (groupIdx >= 0) {
        _focusColumn = FocusColumn.group;
        _focusRow = groupIdx;
      }
      // 自动选择第一个频道（但不播放），仅更新 currentChannel 用于显示 EPG
      if (channels.isNotEmpty) {
        currentChannel = channels.first;
        _updateEpgInfo();
        _showEpgInfoTemporarily();
      } else {
        currentChannel = null;
      }
    });

    _logoService.preloadAllLogos(channels);
    _tryDownloadLogos();
  }

  Future<void> _loadSubscriptionData(Subscription sub) async {
    try {
      final url = sub.url;
      final cacheFile = await PlaylistParser.getCacheFile(url, sub.name);

      if (await cacheFile.exists()) {
        try {
          final content = await cacheFile.readAsString();
          final groupMap = PlaylistParser.parseFromString(content);
          if (groupMap.isNotEmpty) {
            _applyGroupMap(groupMap, sub.name);
          }
        } catch (e) {
          LogService.write('缓存解析失败: $e');
        }
      }

      if (!await cacheFile.exists() || channels.isEmpty) {
        final groupMap = await PlaylistParser.parseFromUrl(url);
        if (groupMap.isNotEmpty) {
          await PlaylistParser.saveCache(groupMap, url, sub.name);
          _applyGroupMap(groupMap, sub.name);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('订阅源加载失败')),
            );
          }
        }
        return;
      }

      if (!_isUpdatingSubscription) {
        _isUpdatingSubscription = true;
        Future.delayed(const Duration(seconds: 2), () async {
          try {
            final newMap = await PlaylistParser.parseFromUrl(url);
            if (newMap.isNotEmpty) {
              final oldCount = _fullGroupMap?.values.expand((l) => l).length ?? 0;
              final newCount = newMap.values.expand((l) => l).length;
              if (oldCount != newCount || newMap.keys.length != groups.length) {
                await PlaylistParser.saveCache(newMap, url, sub.name);
                if (mounted && currentSubName == sub.name) {
                  _applyGroupMap(newMap, sub.name);
                }
              }
            }
          } catch (e) {
            LogService.write('后台更新失败: $e');
          } finally {
            _isUpdatingSubscription = false;
          }
        });
      }
    } catch (e, stack) {
      LogService.writeCrashLog('加载订阅源异常: $e', stack);
    }
  }

  void _applyGroupMap(Map<String, List<Channel>> groupMap, String subName) {
    if (groupMap.isEmpty) return;

    final m3uLogos = <String, String>{};
    for (final list in groupMap.values) {
      for (final ch in list) {
        if (ch.logoUrl != null && ch.logoUrl!.isNotEmpty) {
          m3uLogos[ch.name] = ch.logoUrl!;
        }
      }
    }
    _logoService.updateM3uLogos(m3uLogos);
    _fullGroupMap = groupMap;

    setState(() {
      groups = groupMap.keys.toList();
      if (groups.isNotEmpty) {
        if (currentGroup == null || !groups.contains(currentGroup)) {
          currentGroup = groups.first;
        }
        final groupChannels = groupMap[currentGroup];
        if (groupChannels != null && groupChannels.isNotEmpty) {
          channels = groupChannels;
          if (currentChannel == null && channels.isNotEmpty) {
            final lastChannel = Provider.of<SettingsService>(context, listen: false).getLastChannel();
            if (lastChannel != null) {
              Channel? found;
              for (final list in groupMap.values) {
                try {
                  found = list.firstWhere((ch) => ch.name == lastChannel);
                  break;
                } catch (_) {}
              }
              if (found != null) {
                currentChannel = found;
              } else {
                currentChannel = channels.first;
              }
            } else {
              currentChannel = channels.first;
            }
            _showEpgInfoTemporarily();
            _updateEpgInfo();
          } else if (currentChannel != null && channels.contains(currentChannel)) {
            // OK
          } else {
            if (channels.isNotEmpty) {
              currentChannel = channels.first;
              _updateEpgInfo();
            }
          }
        } else {
          for (final g in groups) {
            final chs = groupMap[g];
            if (chs != null && chs.isNotEmpty) {
              currentGroup = g;
              channels = chs;
              break;
            }
          }
        }
      }
      currentSubName = subName;

      // 重置焦点到第一个频道（列），但只影响焦点位置，不自动播放
      if (channels.isNotEmpty) {
        _focusColumn = FocusColumn.channel;
        _focusRow = 0;
      } else {
        _focusColumn = FocusColumn.subscription;
        _focusRow = 0;
      }
    });

    if (currentChannel != null) {
      _updateEpgInfo();
    }
    _tryDownloadLogos();
  }

  // 数字键处理（保持不变）
  void _handleDigitKey(String digit) {
    _digitTimer?.cancel();
    _digitBuffer += digit;
    _digitTimer = Timer(const Duration(milliseconds: 1500), () {
      _jumpToChannelNumber(_digitBuffer);
      _digitBuffer = '';
    });
  }

  void _jumpToChannelNumber(String digits) {
    if (digits.isEmpty) return;
    final targetNumber = int.tryParse(digits);
    if (targetNumber == null) return;
    Channel? found;
    for (final ch in channels) {
      if (ch.number == targetNumber) {
        found = ch;
        break;
      }
    }
    if (found != null) {
      _switchChannel(found);
    }
  }

  // 遥控器按键处理（核心：自由光标移动）
  void _handleKeyEvent(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    if (!showChannelList || isEditMode || isScheduleMode) return;

    final key = event.logicalKey;
    final digitKeys = [
      LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit9,
    ];
    if (digitKeys.contains(key)) {
      _digitTimer?.cancel();
      _digitBuffer += key.keyLabel;
      _digitTimer = Timer(const Duration(milliseconds: 1500), () {
        _jumpToChannelNumber(_digitBuffer);
        _digitBuffer = '';
      });
      return;
    }

    if (_digitBuffer.isNotEmpty) {
      _digitTimer?.cancel();
      _jumpToChannelNumber(_digitBuffer);
      _digitBuffer = '';
    }

    // 方向键处理
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveFocusRow(-1);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _moveFocusRow(1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      // 左移：订阅 <- 分组 <- 频道
      switch (_focusColumn) {
        case FocusColumn.channel:
          _moveFocusColumn(FocusColumn.group);
          break;
        case FocusColumn.group:
          _moveFocusColumn(FocusColumn.subscription);
          break;
        case FocusColumn.subscription:
          // 在最左边，不做任何事（或循环到频道？根据需求，可以停在边界）
          break;
      }
    } else if (key == LogicalKeyboardKey.arrowRight) {
      switch (_focusColumn) {
        case FocusColumn.subscription:
          _moveFocusColumn(FocusColumn.group);
          break;
        case FocusColumn.group:
          _moveFocusColumn(FocusColumn.channel);
          break;
        case FocusColumn.channel:
          // 在最右边，停在边界
          break;
      }
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select) {
      _executeConfirm();
    }
  }

  // ---------- UI 构建 ----------
  Widget _buildTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _buildEpgInfoBar() {
    final current = _currentProgram;
    final next = _nextProgram;

    String? timeRemaining;
    if (current != null) {
      final now = EpgParser.beijingNow;
      final diff = current.stop.difference(now);
      if (diff.inMinutes > 0) {
        timeRemaining = '距结束：${diff.inMinutes}分钟';
      }
    }

    final List<String> tags = [];
    if (currentSpeed > 0) {
      tags.add('${currentSpeed.toStringAsFixed(2)}MB/s');
    }
    tags.add('线路1/1');

    return Visibility(
      visible: _showEpgInfo,
      child: Container(
        margin: EdgeInsets.symmetric(
          horizontal: MediaQuery.of(context).size.width * 0.15,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          color: Colors.transparent,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (currentChannel != null)
                    ChannelLogo(
                      channelName: currentChannel!.name,
                      width: 80,
                      height: 50,
                      fit: BoxFit.contain,
                    )
                  else
                    const SizedBox(width: 80, height: 50),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          currentChannel?.name ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: tags.map((t) => _buildTag(t)).toList(),
                      ),
                      if (timeRemaining != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            timeRemaining,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (current != null)
                Text(
                  '正在播放：${EpgParser.formatBeijingTime(current.start)} - ${EpgParser.formatBeijingTime(current.stop)}  ${current.title}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                ),
              if (current?.description?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    current!.description!,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '暂无描述信息',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
              const SizedBox(height: 4),
              if (next != null)
                Text(
                  '下一节目：${EpgParser.formatBeijingTime(next.start)} - ${EpgParser.formatBeijingTime(next.stop)}  ${next.title}',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 构建可聚焦的列表项 ----------
  // 订阅项
  Widget _buildSubscriptionItem(Subscription sub, int index) {
    final isFocused = (_focusColumn == FocusColumn.subscription && _focusRow == index);
    final isSelected = currentSubName == sub.name;
    return Container(
      decoration: BoxDecoration(
        color: isFocused ? Colors.blue.withOpacity(0.3) : Colors.transparent,
        border: isFocused ? Border.all(color: Colors.blue, width: 2) : null,
      ),
      child: ListTile(
        title: Text(
          sub.name,
          style: TextStyle(
            color: isSelected ? Colors.yellow : Colors.white,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        onTap: () {
          setState(() {
            _focusColumn = FocusColumn.subscription;
            _focusRow = index;
          });
          _loadSubscriptionData(sub);
        },
      ),
    );
  }

  // 分组项
  Widget _buildGroupItem(String group, int index) {
    final isFocused = (_focusColumn == FocusColumn.group && _focusRow == index);
    final isSelected = group == currentGroup;
    return Container(
      decoration: BoxDecoration(
        color: isFocused ? Colors.blue.withOpacity(0.3) : Colors.transparent,
        border: isFocused ? Border.all(color: Colors.blue, width: 2) : null,
      ),
      child: ListTile(
        title: Text(
          group,
          style: TextStyle(
            color: isSelected ? Colors.yellow : Colors.white70,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 14,
          ),
        ),
        onTap: () {
          setState(() {
            _focusColumn = FocusColumn.group;
            _focusRow = index;
          });
          _switchToGroup(group);
        },
      ),
    );
  }

  // 频道项
  Widget _buildChannelItem(Channel channel, int index) {
    final isFocused = (_focusColumn == FocusColumn.channel && _focusRow == index);
    final isSelected = currentChannel?.name == channel.name;
    final currentEpg = EpgParser.getCurrentProgramSync(channel.name);

    return Container(
      decoration: BoxDecoration(
        color: isFocused ? Colors.blue.withOpacity(0.3) : Colors.transparent,
        border: isFocused ? Border.all(color: Colors.blue, width: 2) : null,
      ),
      child: ListTile(
        dense: true,
        selected: isSelected,
        selectedTileColor: Colors.white.withOpacity(0.1),
        leading: ChannelLogo(
          channelName: channel.name,
          width: 36,
          height: 24,
          fit: BoxFit.contain,
        ),
        title: Text(
          channel.name,
          style: TextStyle(
            color: isSelected ? Colors.yellow : Colors.white,
            fontSize: 14,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: currentEpg != null
            ? Text(
                '${EpgParser.formatBeijingTime(currentEpg.start)}-${EpgParser.formatBeijingTime(currentEpg.stop)} ${currentEpg.title}',
                style: TextStyle(
                  color: isSelected ? Colors.yellow.withOpacity(0.8) : Colors.white70,
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : Text(
                '暂无节目信息',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
        onTap: () {
          setState(() {
            _focusColumn = FocusColumn.channel;
            _focusRow = index;
          });
          _switchChannel(channel);
        },
      ),
    );
  }

  // ---------- 构建列表 ----------
  Widget _buildSubscriptionList() {
    return Consumer<SettingsService>(
      builder: (context, settings, _) {
        final subs = settings.subscriptions;
        _hasSubscriptions = subs.isNotEmpty;
        if (!_hasSubscriptions) {
          return const Center(child: Text('无订阅源', style: TextStyle(color: Colors.white)));
        }
        return ListView.builder(
          itemCount: subs.length,
          itemBuilder: (_, index) => _buildSubscriptionItem(subs[index], index),
        );
      },
    );
  }

  Widget _buildGroupList() {
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (_, index) => _buildGroupItem(groups[index], index),
    );
  }

  Widget _buildChannelListView() {
    return ListView.builder(
      itemCount: channels.length,
      itemBuilder: (_, index) => _buildChannelItem(channels[index], index),
    );
  }

  // ---------- 主构建 ----------
  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    _scheduleButtonInitTop = (screenHeight - 80) / 2;
    _channelButtonInitTop = (screenHeight - 80) / 2;

    // 确保焦点行有效（当列表变化时）
    _clampFocusRow();

    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _handleKeyEvent,
      child: WillPopScope(
        onWillPop: () async {
          if (_showEpgInfo) {
            setState(() => _showEpgInfo = false);
            _epgInfoHideTimer?.cancel();
            return false;
          }
          if (isScheduleMode) {
            setState(() => isScheduleMode = false);
            return false;
          }
          if (showChannelList) {
            setState(() => showChannelList = false);
            return false;
          }
          if (_showRightMenu) {
            setState(() => _showRightMenu = false);
            return false;
          }
          final shouldExit = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('提示'),
              content: const Text('确定要退出应用吗？'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
              ],
            ),
          );
          if (shouldExit == true) exit(0);
          return false;
        },
        child: Scaffold(
          body: Stack(
            children: [
              if (currentChannel != null && currentChannel!.url.isNotEmpty)
                Positioned.fill(
                  child: IjkPlayerWidget(
                    key: _playerKey,
                    url: currentChannel!.url,
                    decoderIndex: Provider.of<SettingsService>(context, listen: false).decoderIndex,
                    onError: _scheduleRetry,
                    onSpeedUpdate: (speed) {
                      if (mounted) setState(() => currentSpeed = speed);
                    },
                  ),
                ),

              if (!_showEpgInfo)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      _showEpgInfoTemporarily();
                    },
                  ),
                ),

              Positioned(
                left: 0, top: 0, bottom: 0, width: 40,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    setState(() {
                      if (isScheduleMode) {
                        isScheduleMode = false;
                        showChannelList = true;
                      } else {
                        showChannelList = !showChannelList;
                      }
                      if (showChannelList) {
                        _showRightMenu = false;
                        _showEpgInfo = false;
                        _epgInfoHideTimer?.cancel();
                        _focusNode.requestFocus();
                      }
                    });
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),

              if (showChannelList && !isScheduleMode)
                Positioned(
                  left: 0, top: 0, bottom: 0,
                  width: MediaQuery.of(context).size.width * 0.7,
                  child: Container(
                    color: Colors.transparent,
                    child: Row(
                      children: [
                        Expanded(flex: (subWeight * 100).toInt(), child: _buildSubscriptionList()),
                        _buildDragBar(onDrag: (delta) {
                          setState(() {
                            double newSub = subWeight + delta;
                            double newGroup = groupWeight - delta;
                            if (newSub < 0.05) newSub = 0.05;
                            if (newGroup < 0.05) newGroup = 0.05;
                            subWeight = newSub;
                            groupWeight = newGroup;
                            channelWeight = 1 - subWeight - groupWeight;
                            if (channelWeight < 0.05) {
                              channelWeight = 0.05;
                              final total = subWeight + groupWeight;
                              subWeight = subWeight / total * 0.95;
                              groupWeight = groupWeight / total * 0.95;
                            }
                          });
                        }, isEditMode: isEditMode),
                        Expanded(flex: (groupWeight * 100).toInt(), child: _buildGroupList()),
                        _buildDragBar(onDrag: (delta) {
                          setState(() {
                            double newGroup = groupWeight + delta;
                            double newChannel = channelWeight - delta;
                            if (newGroup < 0.05) newGroup = 0.05;
                            if (newChannel < 0.05) newChannel = 0.05;
                            groupWeight = newGroup;
                            channelWeight = newChannel;
                            subWeight = 1 - groupWeight - channelWeight;
                            if (subWeight < 0.05) {
                              subWeight = 0.05;
                              final total = groupWeight + channelWeight;
                              groupWeight = groupWeight / total * 0.95;
                              channelWeight = channelWeight / total * 0.95;
                            }
                          });
                        }, isEditMode: isEditMode),
                        Expanded(
                          flex: (channelWeight * 100).toInt(),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: _buildChannelListView(),
                              ),
                              Positioned(
                                right: 20 - channelListButtonOffset.dx,
                                top: _channelButtonInitTop + channelListButtonOffset.dy,
                                child: GestureDetector(
                                  onPanUpdate: (details) {
                                    if (!isEditMode) return;
                                    setState(() => channelListButtonOffset += details.delta);
                                  },
                                  onTap: () => setState(() {
                                    isScheduleMode = true;
                                    showChannelList = false;
                                  }),
                                  child: Container(
                                    width: 26, height: 80, color: Colors.transparent,
                                    child: const Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text('节', style: TextStyle(color: Colors.white, fontSize: 13)),
                                        Text('目', style: TextStyle(color: Colors.white, fontSize: 13)),
                                        Text('单', style: TextStyle(color: Colors.white, fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (isScheduleMode)
                Positioned(
                  left: 0, top: 0, bottom: 0,
                  width: MediaQuery.of(context).size.width * 0.7,
                  child: Stack(
                    children: [
                      Row(
                        children: [
                          Expanded(flex: (scheduleGroupWeight * 100).toInt(), child: _buildGroupList()),
                          _buildDragBar(onDrag: (delta) {
                            setState(() {
                              double newGroup = scheduleGroupWeight + delta;
                              double newChannel = scheduleChannelWeight - delta;
                              if (newGroup < 0.05) newGroup = 0.05;
                              if (newChannel < 0.05) newChannel = 0.05;
                              scheduleGroupWeight = newGroup;
                              scheduleChannelWeight = newChannel;
                              scheduleWeight = 1 - newGroup - newChannel;
                              if (scheduleWeight < 0.05) {
                                scheduleWeight = 0.05;
                                final total = newGroup + newChannel;
                                scheduleGroupWeight = scheduleGroupWeight / total * 0.95;
                                scheduleChannelWeight = scheduleChannelWeight / total * 0.95;
                              }
                            });
                          }, isEditMode: isEditMode),
                          Expanded(
                            flex: (scheduleChannelWeight * 100).toInt(),
                            child: _buildChannelListView(),
                          ),
                          _buildDragBar(onDrag: (delta) {
                            setState(() {
                              double newChannel = scheduleChannelWeight + delta;
                              double newSchedule = scheduleWeight - delta;
                              if (newChannel < 0.05) newChannel = 0.05;
                              if (newSchedule < 0.05) newSchedule = 0.05;
                              scheduleChannelWeight = newChannel;
                              scheduleWeight = newSchedule;
                              scheduleGroupWeight = 1 - newChannel - newSchedule;
                              if (scheduleGroupWeight < 0.05) {
                                scheduleGroupWeight = 0.05;
                                final total = newChannel + newSchedule;
                                scheduleChannelWeight = scheduleChannelWeight / total * 0.95;
                                scheduleWeight = scheduleWeight / total * 0.95;
                              }
                            });
                          }, isEditMode: isEditMode),
                          Expanded(
                            flex: (scheduleWeight * 100).toInt(),
                            child: ScheduleView(
                              channels: channels,
                              selectedChannel: currentChannel,
                              epgMap: const {},
                              onSelectChannel: _switchChannel,
                              leftWeight: 0.3,
                              rightWeight: 0.7,
                              onLeftWeightChanged: (_) {},
                              isEditMode: isEditMode,
                              showLeft: false,
                              logoService: _logoService,
                              getChannelPrograms: _getChannelPrograms,
                              formatTime: _formatTime,
                              beijingNow: _beijingNow,
                            ),
                          ),
                        ],
                      ),
                      Positioned(
                        left: 8 + scheduleModeButtonOffset.dx,
                        top: _scheduleButtonInitTop + scheduleModeButtonOffset.dy,
                        child: GestureDetector(
                          onPanUpdate: (details) {
                            if (!isEditMode) return;
                            setState(() => scheduleModeButtonOffset += details.delta);
                          },
                          onTap: () => setState(() {
                            isScheduleMode = false;
                            showChannelList = true;
                          }),
                          child: Container(
                            width: 26, height: 80, color: Colors.transparent,
                            child: const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('频', style: TextStyle(color: Colors.white, fontSize: 13)),
                                Text('道', style: TextStyle(color: Colors.white, fontSize: 13)),
                                Text('组', style: TextStyle(color: Colors.white, fontSize: 13)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildEpgInfoBar(),
              ),

              if (_showRightMenu)
                Positioned(
                  top: 0, right: 0, bottom: 0,
                  width: MediaQuery.of(context).size.width * 0.12,
                  child: Container(
                    color: Colors.transparent,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildMenuItem(Icons.settings, '设置', () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen()))
                              .then((_) => setState(() {}));
                          setState(() => _showRightMenu = false);
                        }),
                        _buildMenuItem(Icons.edit, '编辑', () {
                          if (isEditMode) {
                            _exitEditMode();
                          } else {
                            setState(() => isEditMode = true);
                          }
                          setState(() => _showRightMenu = false);
                        }),
                        _buildMenuItem(Icons.list, '列表订阅', () {
                          _showAddSubscriptionDialog();
                          setState(() => _showRightMenu = false);
                        }),
                        _buildMenuItem(Icons.tv, 'EPG订阅', () {
                          _showAddEpgDialog();
                          setState(() => _showRightMenu = false);
                        }),
                        _buildMenuItem(Icons.close, '关闭', () {
                          setState(() => _showRightMenu = false);
                        }),
                      ],
                    ),
                  ),
                ),

              Positioned(
                top: 0, right: 0,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, color: Colors.white),
                      onPressed: () {
                        if (isEditMode) {
                          _exitEditMode();
                        } else {
                          setState(() => isEditMode = true);
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white),
                      onPressed: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => SettingsScreen()),
                      ).then((_) => setState(() {})),
                    ),
                    IconButton(
                      icon: const Icon(Icons.menu, color: Colors.white),
                      onPressed: () => setState(() => _showRightMenu = !_showRightMenu),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 拖拽条
  Widget _buildDragBar({required void Function(double) onDrag, required bool isEditMode}) {
    if (!isEditMode) return const SizedBox.shrink();
    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        final width = MediaQuery.of(context).size.width * 0.7;
        onDrag(details.delta.dx / width);
      },
      child: Container(width: 8, color: Colors.white24),
    );
  }

  Widget _buildMenuItem(IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: Colors.white),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      onTap: onTap,
    );
  }

  void _showAddSubscriptionDialog() {}
  void _showAddEpgDialog() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen()),
    ).then((_) => setState(() {}));
  }
}
