# frozen_string_literal: true

# Recreates the Xcode project from the checked-in Swift sources.
# Run with the xcodeproj gem available in GEM_HOME.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'Velora.xcodeproj')
project = Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastUpgradeCheck'] = '2700'
target = project.new_target(:application, 'Velora', :osx, '14.0')
# Mirrors source folders as Xcode groups while keeping one app target.
def add_sources(project, target, root, top_level)
  root_group = project.main_group.new_group(top_level, top_level)
  groups = { '' => root_group }
  Dir.glob(File.join(root, top_level, '**', '*.swift')).sort.each do |path|
    relative = path.delete_prefix(File.join(root, top_level) + '/')
    components = File.dirname(relative).split('/')
    components = [] if components == ['.']
    current = ''
    components.each do |component|
      parent = current
      current = [current, component].reject(&:empty?).join('/')
      groups[current] ||= groups[parent].new_group(component, component)
    end
    reference = groups[current].new_file(File.basename(path))
    target.source_build_phase.add_file_reference(reference)
  end
end

%w[App Domain Data Features].each { |folder| add_sources(project, target, root, folder) }
assets = project.main_group.children.find { |group| group.display_name == 'App' }.new_file('Assets.xcassets')
target.resources_build_phase.add_file_reference(assets)


tests = project.new_target(:unit_test_bundle, 'VeloraTests', :osx, '14.0')
tests.add_dependency(target)
add_sources(project, tests, root, 'Tests')

project.build_configurations.each do |configuration|
  configuration.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  configuration.build_settings['SWIFT_VERSION'] = '5.0'
end

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.velora.app'
  settings['PRODUCT_NAME'] = 'Velora'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['INFOPLIST_FILE'] = 'App/Info.plist'
  settings['MARKETING_VERSION'] = '0.1.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'Velora'
  settings['INFOPLIST_KEY_CFBundleShortVersionString'] = '0.1.0'
  settings['INFOPLIST_KEY_NSMicrophoneUsageDescription'] = '将你的语音转换为可预览的 Velora 操作指令。'
  settings['INFOPLIST_KEY_NSSpeechRecognitionUsageDescription'] = '识别你主动录入的语音指令，用于操作 Velora。'
  settings['INFOPLIST_KEY_LSApplicationCategoryType'] = 'public.app-category.productivity'
  settings['SWIFT_VERSION'] = '5.0'
  settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  settings['OTHER_LDFLAGS'] = ['$(inherited)', '-lsqlite3']
  settings['CODE_SIGNING_ALLOWED'] = 'NO'
end

tests.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.velora.app.tests'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Velora.app/Contents/MacOS/Velora'
  settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  settings['CODE_SIGNING_ALLOWED'] = 'NO'
end

project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(tests)
scheme.save_as(project_path, 'Velora')
puts project_path
