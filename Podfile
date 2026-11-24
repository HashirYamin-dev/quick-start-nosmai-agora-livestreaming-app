platform :ios, '15.0'

target 'NosmaiAgoraDemo' do
  use_frameworks!

  pod 'NosmaiCameraSDK', '3.0.7'
  pod 'AgoraRtcEngine_iOS', '4.6.4'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0' }
  end
end
