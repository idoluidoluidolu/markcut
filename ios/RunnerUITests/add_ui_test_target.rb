# 診斷用：在 CI 上臨時加一個 UI 測試 target 與 scheme（不改 repo 裡的專案檔）
require 'xcodeproj'

proj_path = File.expand_path('../Runner.xcodeproj', __dir__)
project = Xcodeproj::Project.open(proj_path)
app = project.targets.find { |t| t.name == 'Runner' } or abort('no Runner target')

ui = project.new_target(:ui_test_bundle, 'RunnerUITests', :ios, '15.0', nil, :swift)
ui.build_configurations.each do |c|
  s = c.build_settings
  s['TEST_TARGET_NAME'] = 'Runner'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.idoluidoluidolu.watermark.RunnerUITests'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['CODE_SIGN_STYLE'] = 'Automatic'
end

group = project.main_group.new_group('RunnerUITests', 'RunnerUITests')
ref = group.new_reference('GifPickUITests.swift')
ui.add_file_references([ref])
ui.add_dependency(app)
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(ui)
scheme.set_launch_target(app)
scheme.save_as(proj_path, 'RunnerUITests', true)
puts "added RunnerUITests target + scheme to #{proj_path}"
