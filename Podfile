# Uncomment this line to define a global platform for your project
# platform :ios, "6.0"

source 'https://github.com/CocoaPods/Specs.git'

target "MatrixKitSample" do


# Different flavours of pods to Matrix SDK
# The tagged version on which this version of MatrixKit has been built
#pod 'MatrixSDK', '0.6.17'

# The lastest release available on the CocoaPods repository 
#pod 'MatrixSDK'

# The modified for juuj version (removing UIWebview, and renaming didSelectContact method)
pod 'MatrixSDK', :git => 'https://github.com/VooduVibe-Dev/matrix-ios-sdk-v0.6.17.git'

# The one used for developping both MatrixSDK and MatrixKit
# Note that MatrixSDK must be cloned into a folder called matrix-ios-sdk next to the MatrixKit folder
#pod 'MatrixSDK', :path => '../matrix-ios-sdk/MatrixSDK.podspec'

pod 'libPhoneNumber-iOS', '~> 0.8.14'
pod 'HPGrowingTextView', '~> 1.1'
pod 'JSQMessagesViewController', '~> 7.2.0'
pod 'DTCoreText', '~> 1.6.17'
pod 'GHMarkdownParser', '~> 0.1.2'

end

target "MatrixKitTests" do

end
