Pod::Spec.new do |s|
  s.name             = 'push_kit'
  s.version          = '1.0.2'
  s.summary          = 'Flutter push notifications for Huawei, Xiaomi, OPPO, vivo and Apple.'
  s.description      = s.summary
  s.homepage         = 'https://github.com/Wgga/push_kit'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Wgga' => 'opensource@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.frameworks       = 'UserNotifications'
  s.platform         = :ios, '12.0'
  s.static_framework = true
end
