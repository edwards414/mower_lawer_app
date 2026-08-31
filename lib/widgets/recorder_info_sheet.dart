import 'package:flutter/material.dart';

/// Explains *how the bag-recording system is designed* — surfaced from the
/// recorder screen's ℹ️ button. Content mirrors the on-robot `mower_recorder`
/// package (recorder_manager / graph_snapshot / bag_store nodes) and the
/// rosbridge contract the app drives it over.
class RecorderInfoSheet extends StatelessWidget {
  const RecorderInfoSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                Icon(Icons.fiber_smart_record, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '錄製 Bag 的設計邏輯',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'mower_recorder · 田野 bag 系統',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                _lead(
                  '這是一套「田野 bag 系統」,目標是把重現一趟戶外作業所需的'
                  '三個層面完整記錄下來 — 而不只是 topic。錄下來的 .mcap 可用 '
                  'Foxglove Studio 或 ros2 bag play 分析與重播。',
                  cs,
                ),
                const SizedBox(height: 20),

                // ── 三個記錄層面 ──────────────────────────────────────────
                _SectionCard(
                  icon: Icons.layers_outlined,
                  title: '三個記錄層面 (planes)',
                  children: [
                    _Plane(
                      n: '①',
                      color: Colors.blue,
                      title: '資料 data',
                      body:
                          'odom / tf / cmd_vel / battery / GPS / 地圖圖層 / '
                          'Nav2 / rosout 等白名單 topic,經 rosbag2 存成 '
                          'mcap + zstd 壓縮,依大小(512MB)或時間(1hr)分段。'
                          'latched 地圖用 QoS overrides 才能正確重播。',
                    ),
                    _Plane(
                      n: '②',
                      color: Colors.teal,
                      title: '圖 graph',
                      body:
                          'graph_snapshot_node 每 2 秒把「節點 / topic / '
                          'service 狀態」拍成 JSON 發到 /graph_snapshot 寫進 '
                          'bag,並在任何節點消失時記 WARN(rosbag2 本身不會錄圖)。',
                    ),
                    _Plane(
                      n: '③',
                      color: Colors.deepOrange,
                      title: '中繼資料 metadata',
                      body:
                          'run_id、robot_id、git sha、GPS 起點 → 寫進 bag '
                          '旁邊的 run_metadata.yaml;關鍵節點的 param dump '
                          '另存到 params/ 目錄。',
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── 三個節點 ──────────────────────────────────────────────
                _SectionCard(
                  icon: Icons.hub_outlined,
                  title: '三個節點',
                  children: [
                    _Bullet(
                      lead: 'recorder_manager_node',
                      text:
                          '開始 / 停止 rosbag2、寫 metadata、提供 '
                          'start / stop / snapshot 服務,收到 fault 時 flush '
                          'snapshot 緩衝。',
                    ),
                    _Bullet(
                      lead: 'graph_snapshot_node',
                      text:
                          '記錄圖狀態,並在被監看的節點(map_manage_node、'
                          'boustrophedon_coverage)死掉時觸發 fault。',
                    ),
                    _Bullet(
                      lead: 'bag_store_node',
                      text:
                          '清單 / 更名 / 刪除,並在網路 OK 時自動上傳到 '
                          'Cloudflare R2。',
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── 生命週期與容錯 ────────────────────────────────────────
                _SectionCard(
                  icon: Icons.autorenew,
                  title: '生命週期與容錯',
                  children: [
                    _Bullet(
                      lead: 'Autostart',
                      text:
                          '啟動後等 3 秒(讓 graph 長好、metadata 抓得到)'
                          '才自動開始錄。',
                    ),
                    _Bullet(
                      lead: 'SIGINT 收尾',
                      text:
                          '停止用服務或 Ctrl-C(SIGINT),不要 kill -9 — '
                          'mcap 才會被 finalize + 建索引。',
                    ),
                    _Bullet(
                      lead: 'Fault → snapshot',
                      text:
                          '重的 topic(global/local costmap、plan)平常只在 '
                          'RAM 緩衝(256MB),發生 fault 才落地到 snapshots/。',
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── App ↔ 機器人 ─────────────────────────────────────────
                _SectionCard(
                  icon: Icons.sync_alt,
                  title: 'App ↔ 機器人(rosbridge)',
                  subtitle: '全程用 std_msgs/String,不需自訂 srv、免重建介面',
                  children: const [
                    _TopicRow(
                      dir: _Dir.subLatched,
                      topic: '/mower_recorder/status',
                      desc: '錄製中橫幅(run_id、時間、大小、topic 數)',
                    ),
                    _TopicRow(
                      dir: _Dir.subLatched,
                      topic: '/mower_recorder/bags',
                      desc: '錄製檔清單 + 網路 / R2 狀態',
                    ),
                    _TopicRow(
                      dir: _Dir.pub,
                      topic: '/mower_recorder/command',
                      desc: 'refresh / rename / delete / upload_now',
                    ),
                    _TopicRow(
                      dir: _Dir.sub,
                      topic: '/mower_recorder/command_result',
                      desc: '操作結果訊息(toast)',
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── 上傳 R2 ──────────────────────────────────────────────
                _SectionCard(
                  icon: Icons.cloud_upload_outlined,
                  title: '上傳 Cloudflare R2',
                  children: [
                    _Bullet(
                      lead: 'WiFi 判斷',
                      text:
                          '只有在好網路(WiFi 介面有 IPv4,或已回充電座)才上傳;'
                          '4G 期間 run 留在磁碟排隊,回 WiFi / docked 再補傳。',
                    ),
                    _Bullet(lead: '安全鎖', text: '正在錄製中的 run 不會被上傳或刪除。'),
                  ],
                ),
                const SizedBox(height: 16),

                // ── 不進 bag ─────────────────────────────────────────────
                _SectionCard(
                  icon: Icons.videocam_off_outlined,
                  title: '不放進 bag 的東西',
                  children: [
                    _Bullet(
                      lead: '相機 / 點雲',
                      text:
                          '影像走 WebRTC / MediaMTX 串流,用時間戳跟 bag 對齊。'
                          'bag = 遙測 / 狀態,影像 = 各自的串流。',
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── 磁碟結構 ─────────────────────────────────────────────
                _SectionCard(
                  icon: Icons.folder_outlined,
                  title: '一趟 run 的磁碟結構',
                  children: const [_RunTree()],
                ),
                const SizedBox(height: 16),

                _tip(
                  '巧思:錄的是 /adapter/* 這些「app 直接訂閱」的 topic,所以 '
                  'ros2 bag play 可以直接驅動 app — 不需要 sim、Nav2、'
                  '甚至 flutter_adapter。',
                  cs,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _lead(String text, ColorScheme cs) => Text(
    text,
    style: TextStyle(
      fontSize: 14,
      height: 1.5,
      color: cs.onSurface.withValues(alpha: 0.85),
    ),
  );

  Widget _tip(String text, ColorScheme cs) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: cs.primaryContainer.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lightbulb_outline, size: 18, color: cs.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.5)),
        ),
      ],
    ),
  );
}

/// A titled, outlined card grouping related rows.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 26),
              child: Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 11.5,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

/// One of the ①②③ recording planes.
class _Plane extends StatelessWidget {
  const _Plane({
    required this.n,
    required this.color,
    required this.title,
    required this.body,
  });

  final String n;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Text(
              n,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: cs.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A `lead — text` bullet.
class _Bullet extends StatelessWidget {
  const _Bullet({required this.lead, required this.text});

  final String lead;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 8),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: 12.8,
                  height: 1.45,
                  color: cs.onSurface.withValues(alpha: 0.82),
                ),
                children: [
                  TextSpan(
                    text: '$lead — ',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(text: text),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _Dir { pub, sub, subLatched }

/// A rosbridge topic row with a direction chip.
class _TopicRow extends StatelessWidget {
  const _TopicRow({required this.dir, required this.topic, required this.desc});

  final _Dir dir;
  final String topic;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    late final String label;
    late final Color color;
    switch (dir) {
      case _Dir.pub:
        label = 'PUB';
        color = Colors.orange;
      case _Dir.sub:
        label = 'SUB';
        color = Colors.blue;
      case _Dir.subLatched:
        label = 'SUB◆';
        color = Colors.indigo;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            padding: const EdgeInsets.symmetric(vertical: 2),
            margin: const EdgeInsets.only(top: 1),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  topic,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The on-disk layout of one recorded run.
class _RunTree extends StatelessWidget {
  const _RunTree();

  static const _lines = [
    ['<output_root>/<robot_id>_<timestamp>/', ''],
    ['├── bag/', '完整錄製 mcap(分段 _0.mcap, _1.mcap …)'],
    ['├── snapshots/', '重 topic,只在 fault 時寫'],
    ['├── params/', '啟動時關鍵節點的 param dump'],
    ['└── run_metadata.yaml', 'run_id / git sha / GPS 起點'],
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in _lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                  children: [
                    TextSpan(
                      text: line[0],
                      style: TextStyle(color: cs.onSurface),
                    ),
                    if (line[1].isNotEmpty)
                      TextSpan(
                        text: '   # ${line[1]}',
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
