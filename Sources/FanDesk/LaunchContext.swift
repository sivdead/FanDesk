import Foundation

func isLoginLaunchEvent(event: NSAppleEventDescriptor?) -> Bool {
    guard let event, event.eventID == AEEventID(0x6f617070) else { return false } // 'oapp'
    let propertyData = event.paramDescriptor(forKeyword: AEKeyword(0x70726474)) // 'prdt'
    return propertyData?.enumCodeValue == OSType(0x6c676974) // 'lgit'
}
