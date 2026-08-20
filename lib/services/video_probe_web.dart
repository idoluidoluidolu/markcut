/// Web 版沒有原生解碼器，播放偵測只在手機上有意義
Future<void> runVideoProbe(String path, void Function(String) log) async {
  log('Web 版沒有原生解碼器，播放偵測請在手機上跑');
}
