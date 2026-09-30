import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import '../utils/app_icons.dart';

/// What the operator should do next on the map, derived from the mission
/// state, so the four panels are not something they have to work out alone.
class MissionNextStep {
  const MissionNextStep({
    required this.text,
    this.actionLabel,
    this.targetMode,
    this.addObject = false,
  });

  final String text;
  final String? actionLabel;

  /// Panel the action switches to; null when the action opens the add sheet.
  final MissionMode? targetMode;
  final bool addObject;

  /// Null when another on-map flow (recording, drawing, editing) already owns
  /// the guidance, so two prompts never compete.
  static MissionNextStep? of(MissionMockProvider mission) {
    if (mission.recordingType != null ||
        mission.hasPendingRecordSave ||
        mission.drawMode ||
        mission.editVertexMode) {
      return null;
    }
    final running =
        mission.navStatus == NavMockStatus.executing ||
        mission.navStatus == NavMockStatus.paused;
    final mode = mission.selectedMode;
    if (running) {
      return MissionNextStep(
        text: '任務進行中',
        actionLabel: mode == MissionMode.run ? null : '查看執行',
        targetMode: MissionMode.run,
      );
    }
    if (mission.zones.isEmpty) {
      return const MissionNextStep(
        text: '第一步：新增工作區，開車繞一圈記錄邊界',
        actionLabel: '新增工作區',
        addObject: true,
      );
    }
    if (!mission.zones.any((zone) => zone.hasCoveragePath)) {
      return MissionNextStep(
        text: '第二步：為工作區生成覆蓋路徑',
        actionLabel: mode == MissionMode.plan ? null : '前往規劃',
        targetMode: MissionMode.plan,
      );
    }
    return MissionNextStep(
      text: '路徑已就緒：選擇區域後即可開始割草',
      actionLabel: mode == MissionMode.run ? null : '前往執行',
      targetMode: MissionMode.run,
    );
  }
}

class MissionNextStepBanner extends StatelessWidget {
  const MissionNextStepBanner({super.key, required this.onAddObject});

  final VoidCallback onAddObject;

  @override
  Widget build(BuildContext context) {
    // A short (landscape) panel has no room for a banner.
    if (MediaQuery.sizeOf(context).height < 420) {
      return const SizedBox.shrink();
    }
    final mission = context.watch<MissionMockProvider>();
    final step = MissionNextStep.of(mission);
    if (step == null) {
      return const SizedBox.shrink();
    }
    final label = step.actionLabel;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFE4F6EC),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          child: Row(
            children: [
              const Icon(
                AppIcons.circlePlay,
                size: 18,
                color: Color(0xFF167A4A),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  step.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF0F5A36),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (label != null)
                TextButton(
                  onPressed: () {
                    if (step.addObject) {
                      onAddObject();
                    } else if (step.targetMode != null) {
                      mission.selectMode(step.targetMode!);
                    }
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF167A4A),
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
