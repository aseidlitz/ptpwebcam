//
//  PtpWebcamPlugin.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 30.05.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamPlugin.h"
#import "PtpWebcamPtpDevice.h"
#import "PtpWebcamPtpStream.h"
#import "PtpWebcamXpcDevice.h"
#import "PtpWebcamXpcStream.h"
#import "PtpWebcamDummyDevice.h"
#import "PtpWebcamDummyStream.h"
#import "PtpWebcamAlerts.h"

#import "../PtpWebcamAssistantService/PtpWebcamAssistantServiceProtocol.h"
#import "../PtpWebcamAssistantService/PtpCameraProtocol.h"
//#import "../PtpWebcamAgent/PtpWebcamAgentProtocol.h"

#import <ImageCaptureCore/ImageCaptureCore.h>

#import <ServiceManagement/ServiceManagement.h>

// define DUMMY_DEVICE_ENABLED to enable the dummy device to test that the DAL plugin can deliver images without a camera connection
//#define DUMMY_DEVICE_ENABLED=1

@interface PtpWebcamPlugin ()
{
	ICDeviceBrowser* deviceBrowser;
	
	NSXPCConnection* assistantConnection;
}
@end

@implementation PtpWebcamPlugin

- (instancetype) init
{
	if (!(self = [super init]))
		return nil;
	
	self.cmioDevices = @[];
	self.cameras = @[];
	
	return self;
}

- (BOOL) isDalaSystemInitingOrExiting
{
	CMIOObjectPropertyAddress propAddr = {
		.mSelector = kCMIOHardwarePropertyIsInitingOrExiting,
		.mScope = kCMIOObjectPropertyScopeGlobal,
		.mElement = kCMIOObjectPropertyElementMaster,
	};
	uint32_t dataUsed = 0;
	uint32_t isInitingOrExiting = 0;
	CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &propAddr, 0, NULL, sizeof(isInitingOrExiting), &dataUsed, &isInitingOrExiting);
	
	return isInitingOrExiting != 0;
}

- (BOOL) isDalaSystemMaster
{
	CMIOObjectPropertyAddress propAddr = {
		.mSelector = kCMIOHardwarePropertyProcessIsMaster,
		.mScope = kCMIOObjectPropertyScopeGlobal,
		.mElement = kCMIOObjectPropertyElementMaster,
	};
	uint32_t dataUsed = 0;
	uint32_t isMaster = 0;
	CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &propAddr, 0, NULL, sizeof(isMaster), &dataUsed, &isMaster);
	
	return isMaster != 0;

}

- (void) deviceRemoved: (id) device
{
	
}

- (OSStatus) initialize
{
#ifdef XPC_ASSISTANT_ENABLED
	[self connectToAssistantService];
#else
	deviceBrowser = [[ICDeviceBrowser alloc] init];
	deviceBrowser.delegate = self;
	deviceBrowser.browsedDeviceTypeMask |= ICDeviceTypeMaskCamera | ICDeviceLocationTypeMaskLocal;
	
	[deviceBrowser start];
#endif
	
#ifdef DUMMY_DEVICE_ENABLED
	[self createDummyDeviceAndStream];
#endif
	
//	[self createStatusItem];

	return kCMIOHardwareNoError;
}

- (OSStatus) teardown
{
	if (deviceEventDispatchSource)
	{
		dispatch_source_cancel(deviceEventDispatchSource);
		deviceEventDispatchSource = NULL;
	}
	
	// Do the full teardown if this is outside of the process being torn down or this is the master process
	if (![self isDalaSystemInitingOrExiting] || [self isDalaSystemMaster])
	{
		for (id device in self.cmioDevices.copy)
		{
			[self deviceRemoved: device];
		}
	}
	else
	{
		for (PtpWebcamDevice* device in self.cmioDevices.copy)
		{
			[device unplugDevice];
			[device finalizeDevice];
		}

	}
	
//	[self removeStatusItem];

	return kCMIOHardwareNoError;
}


- (void) createDummyDeviceAndStream
{
	PtpWebcamDummyDevice* device = [[PtpWebcamDummyDevice alloc] initWithPluginInterface: self.pluginInterfaceRef];
	[device createCmioDeviceWithPluginId: self.objectId];
	[PtpWebcamObject registerObject: device];
	
	PtpWebcamDummyStream* stream = [[PtpWebcamDummyStream alloc] initWithPluginInterface: self.pluginInterfaceRef];
	[stream createCmioStreamWithDevice: device];
	[PtpWebcamObject registerObject: stream];

	// then publish stream and device
	[device publishCmioDevice];
	[stream publishCmioStream];
	
	@synchronized (self) {
		NSMutableArray* devices = self.cmioDevices.mutableCopy;
		[devices addObject: device];
		self.cmioDevices = devices;
	}

}

- (void) cameraDidBecomeReadyForUse:(PtpCamera *)camera
{
	PtpWebcamPtpDevice* device = [[PtpWebcamPtpDevice alloc] initWithCamera: camera pluginInterface: self.pluginInterfaceRef];
	[device createCmioDeviceWithPluginId: self.objectId];
	[PtpWebcamObject registerObject: device];
	
	PtpWebcamPtpStream* stream = [[PtpWebcamPtpStream alloc] initWithPluginInterface: self.pluginInterfaceRef];
	stream.ptpDevice = device;
	[stream createCmioStreamWithDevice: device];
	[PtpWebcamObject registerObject: stream];

	// then publish stream and device
	[device publishCmioDevice];
	[stream publishCmioStream];
	
	@synchronized (self) {
		NSMutableArray* devices = self.cmioDevices.mutableCopy;
		[devices addObject: device];
		self.cmioDevices = devices;
	}

}

- (void) receivedCameraProperty:(NSDictionary *)propertyInfo withId:(NSNumber *)propertyId fromCamera:(PtpCamera *)camera
{
	// do nothing when receiving camera properties during enumeration
}

- (void) deviceDidBecomeReadyWithCompleteContentCatalog:(ICCameraDevice *)icCamera
{
	NSLog(@"deviceDidBecomeReadyWithCompleteContentCatalog %@", icCamera);
	
	// create and register stream and device
	
	PtpCamera* camera = [PtpCamera cameraWithIcCamera: icCamera delegate: self];

	@synchronized (self) {
		NSMutableArray* cameras = self.cameras.mutableCopy;
		[cameras addObject: camera];
		self.cameras = cameras;
	}

}

- (void)deviceBrowser:(ICDeviceBrowser*)browser didAddDevice:(ICDevice*)camera moreComing:(BOOL) moreComing
{
//	NSLog(@"add device %@", device);
	NSDictionary* cameraInfo = [PtpCamera isDeviceSupported: camera];
	if (cameraInfo)
	{
		if (![cameraInfo[@"confirmed"] boolValue])
		{
			PTPWebcamShowCameraIssueBlockingAlert(cameraInfo[@"make"], cameraInfo[@"model"]);
		}
//		NSLog(@"camera capabilities %@", camera.capabilities);
		camera.delegate = self;
		[camera requestOpenSession];

	}
}

- (void)deviceBrowser:(nonnull ICDeviceBrowser *)browser didRemoveDevice:(nonnull ICDevice *)icDevice moreGoing:(BOOL)moreGoing
{
	NSLog(@"remove device %@", icDevice);
	
	for(PtpWebcamDevice* device in self.cmioDevices.copy)
	{
		if ([device isKindOfClass: [PtpWebcamPtpDevice class]])
		{
			PtpWebcamPtpDevice* ptpDevice = (id)device;
			if ([icDevice isEqual: ptpDevice.camera.icCamera])
			{
//				[ptpDevice unplugDevice];
				@synchronized (self) {
					NSMutableArray* devices = self.cmioDevices.mutableCopy;
					[devices removeObject: device];
					self.cmioDevices = devices;
				}
			}
		}
	}
	for (PtpCamera* camera in self.cameras.copy)
	{
		if ([icDevice isEqual: camera.icCamera])
		{
			@synchronized (self) {
				NSMutableArray* cameras = self.cameras.mutableCopy;
				[cameras removeObject: cameras];
				self.cameras = cameras;
			}
		}
	}
}


- (void) device:(ICDevice *)device didOpenSessionWithError:(NSError *)error
{
	NSLog(@"device didOpenSession");
	if (error)
		NSLog(@"device could not open session because %@", error);
	
}

- (void)device:(nonnull ICDevice *)device didCloseSessionWithError:(nonnull NSError *)error {
}


- (void)didRemoveDevice:(nonnull ICDevice *)device {
}



//- (void)deviceBrowser:(ICDeviceBrowser*)browser didRemoveDevice:(ICDevice*)device moreGoing:(BOOL) moreGoing
//{
//	NSLog(@"remove device %@", device);
//
////	if (self.device.cameraDevice == cameraDevice)
////	{
////		[self.device.stream stopStream];
////		cameraDevice = nil;
////	}
//
//}

//- (NSData * _Nullable)getPropertyDataForAddress:(CMIOObjectPropertyAddress)address qualifierData:(nonnull NSData *)qualifierData {
//	<#code#>
//}
//
//- (uint32_t)getPropertyDataSizeForAddress:(CMIOObjectPropertyAddress)address qualifierData:(NSData * _Nullable)qualifierData {
//	<#code#>
//}
//
//- (BOOL)hasPropertyWithAddress:(CMIOObjectPropertyAddress)address {
//	<#code#>
//}
//
//- (BOOL)isPropertySettable:(CMIOObjectPropertyAddress)address {
//	<#code#>
//}
//
//- (OSStatus)setPropertyDataForAddress:(CMIOObjectPropertyAddress)address qualifierData:(NSData * _Nullable)qualifierData data:(nonnull NSData *)data {
//	<#code#>
//}

// MARK: Assistant Service

- (void) connectToAssistantService
{
//	assistantConnection = [[NSXPCConnection alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAssistant" options: 0];

	assistantConnection = [[NSXPCConnection alloc] initWithServiceName: @"org.ptpwebcam.PtpWebcamAssistantService"];

	__weak NSXPCConnection* weakConnection = assistantConnection;
	assistantConnection.invalidationHandler = ^{
		NSLog(@"oops, connection failed: %@", weakConnection);
	};
	assistantConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantServiceProtocol)];
	
//	NSXPCInterface* cameraInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpCameraProtocol)];
	NSXPCInterface* exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamAssistantDelegateProtocol)];
//	[exportedInterface setInterface: cameraInterface forSelector: @selector(cameraConnected:) argumentIndex: 0 ofReply: NO];
	
	assistantConnection.exportedObject = self;
	assistantConnection.exportedInterface = exportedInterface;
	
	[assistantConnection resume];
	
	// send message to get the service started by launchd
	[[assistantConnection remoteObjectProxy] pingService:^{
		PtpLog(@"pong received.");
	}];

}

- (nullable id) xpcDeviceWithId: (id) cameraId
{
	for (PtpWebcamDevice* device in self.cmioDevices)
	{
		if ([device isKindOfClass: [PtpWebcamXpcDevice class]])
		{
			PtpWebcamXpcDevice* xpcDevice = (id)device;
			if ([xpcDevice.cameraId isEqual: cameraId])
				return xpcDevice;
		}
	}
	return nil;
}

- (void) cameraConnected: (id) cameraId withInfo: (NSDictionary*) cameraInfo
{
//	PtpLog(@"");
	
	// create and register stream and device
	
	PtpWebcamXpcDevice* device = [[PtpWebcamXpcDevice alloc] initWithCameraId: cameraId info: cameraInfo pluginInterface: self.pluginInterfaceRef];

	// checking and adding to self.devices must happen atomically, hence the @sync block
	@synchronized (self) {
		// do nothing if we already know of the camera
		if ([self xpcDeviceWithId: cameraId])
			return;
		
		// add to devices list
		NSMutableArray* devices = self.cmioDevices.mutableCopy;
		[devices addObject: device];
		self.cmioDevices = devices;
	}

	device.xpcConnection = assistantConnection;

	[device createCmioDeviceWithPluginId: self.objectId];
	[PtpWebcamObject registerObject: device];
	
	PtpWebcamXpcStream* stream = [[PtpWebcamXpcStream alloc] initWithPluginInterface: self.pluginInterfaceRef];
	stream.xpcDevice = device;
	[stream createCmioStreamWithDevice: device];
	[PtpWebcamObject registerObject: stream];

	// then publish stream and device
	[device publishCmioDevice];
	[stream publishCmioStream];
	

}

- (void)cameraDisconnected:(id)cameraId
{
	
	PtpWebcamXpcDevice* device = nil;
	@synchronized (self) {
		// do nothing if we didn't know about the camera
		if (!(device = [self xpcDeviceWithId: cameraId]))
			return;
		
		// remove from devices list
		NSMutableArray* devices = self.cmioDevices.mutableCopy;
		[devices removeObject: device];
		self.cmioDevices = devices;
	}
	
	[device unplugDevice];

}


- (void) liveViewReadyforCameraWithId:(id)cameraId
{
	PtpWebcamXpcDevice* device = [self xpcDeviceWithId: cameraId];
	PtpWebcamXpcStream* stream = (id)device.stream;
	[stream liveViewStreamReady];

}

- (void) receivedLiveViewJpegImageData:(NSData *)jpegData withInfo:(NSDictionary *)info forCameraWithId:(id)cameraId
{
	PtpWebcamXpcDevice* device = [self xpcDeviceWithId: cameraId];
	PtpWebcamXpcStream* stream = (id)device.stream;
	[stream receivedLiveViewJpegImageData: jpegData withInfo: info];
}


//- (void)propertyChanged:(NSDictionary *)property forCameraWithId:(id)cameraId {
//	<#code#>
//}


@end
