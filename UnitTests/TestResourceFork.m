//
//  TestResourceFork.m
//  UnitTests
//
//  Created by Peter Hosey on 2023-03-23.
//

#import <XCTest/XCTest.h>

#import "ImpPrintf.h"
#import "ImpByteOrder.h"
#import "NSData+ImpHexDump.h"

#import "ImpDehydratedResourceFork.h"

@interface ImpDehydratedResourceFork (ImpTestingExtensions)

- (instancetype _Nullable) initWithData:(NSData *_Nonnull const)forkData;

@end

@interface TestResourceFork : XCTestCase

@end

@implementation TestResourceFork
{
	ImpDehydratedResourceFork *_rsrcFork;
}

- (void)setUp {
	self.continueAfterFailure = false;

	NSBundle *_Nonnull const testBundle = [NSBundle bundleForClass:[self class]];
	NSURL *_Nonnull const resourceFileDataForkURL = [testBundle URLForResource:@"UnitTests" withExtension:@"rsrc"];
	//Xcode compiles the .r file to a data-fork resource file.
//	NSURL *_Nonnull const resourceFileResourceForkURL = [resourceFileDataForkURL URLByAppendingPathComponent:@"..namedfork/rsrc" isDirectory:false];
	NSData *_Nonnull const resourceForkData = [NSData dataWithContentsOfURL:resourceFileDataForkURL];
	_rsrcFork = [[ImpDehydratedResourceFork alloc] initWithData:resourceForkData];
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
}

- (void) testFirstReadingTestFile {
	XCTAssertNotNil(_rsrcFork);
}

- (void) testReadResourceOfTypeNotPresent {
	NSData *_Nullable const resData = [_rsrcFork resourceOfType:'FAKE' ID:128];
	XCTAssertNil(resData);
}
///Attempt to read a resource of a type that we do have resources of, but of an ID that no resource of that type that we have has.
- (void) testReadResourceOfIDNotPresent {
	NSData *_Nullable const resData = [_rsrcFork resourceOfType:'STR#' ID:999];
	XCTAssertNil(resData);
}

///Attempt to read a resource that exists in our resources file.
- (void) testReadStringsResource {
	NSData *_Nullable const resData = [_rsrcFork resourceOfType:'STR#' ID:128];
	XCTAssertNotNil(resData);

	NSUInteger const expectedLength = 0x21;
	XCTAssertEqual(resData.length, expectedLength);

	void const *_Nonnull const bytesPtr = resData.bytes;
	UInt16 const *_Nonnull const countPtr = bytesPtr;
	XCTAssertEqual(L(*countPtr), (UInt16)5);

	//Our first string is supposed to be “Alpha”, and occupies the fourth through ninth bytes.
	NSRange const str0Range = { 3, 5 };
	NSData *_Nonnull const str0Data = [resData subdataWithRange:str0Range];
	NSData *_Nonnull const expectedStr0Data = [@"Alpha" dataUsingEncoding:NSMacOSRomanStringEncoding];
	XCTAssertEqualObjects(str0Data, expectedStr0Data, @"First string should be “Alpha” but it was not; here's a hex dump: %@", [str0Data hexDump_Imp]);
}

- (void) testParseBCDByte {
	u_int8_t const inputNumber = 0x12;
	u_int8_t const outputNumber = 12;
	XCTAssertEqual(ImpParseBCDByte(inputNumber), outputNumber);
}

- (void) testReadVersionResource {
	NSData *_Nullable const resData = [_rsrcFork resourceOfType:'vers' ID:128];
	XCTAssertNotNil(resData);

	NSUInteger const expectedLength = 0x45;
	XCTAssertEqual(resData.length, expectedLength);

	void const *_Nonnull const bytesPtr = resData.bytes;
	struct ImpFixed_VersRec const *_Nonnull const version = bytesPtr;

	NSLog(@"Major version: 0x%02x", version->numericVersion.majorRev);
	NSLog(@"Stage: 0x%02x", version->numericVersion.stage);
	NSLog(@"Non-release version: 0x%02x", version->numericVersion.nonRelRev);

	NSLog(@"Major version high: %d", (version->numericVersion.majorRev >> 4) & 0xf);
	NSLog(@"Major version low: %d", (version->numericVersion.majorRev >> 0) & 0xf);
	NSLog(@"Major version: %d", ImpParseBCDByte(version->numericVersion.majorRev));
	NSLog(@"Minor version: %d", (version->numericVersion.minorRev));
	NSLog(@"Bug-fix version: %d", (version->numericVersion.bugFixRev));
	NSLog(@"Stage: 0x%02x", version->numericVersion.stage);
	NSLog(@"Non-release version high: %d", (version->numericVersion.nonRelRev >> 4) & 0xf);
	NSLog(@"Non-release version low: %d", (version->numericVersion.nonRelRev >> 0) & 0xf);
	NSLog(@"Non-release version: %d", ImpParseBCDByte(version->numericVersion.nonRelRev));
	XCTAssertEqual(version->numericVersion.majorRev, 0x12);
	XCTAssertEqual(version->numericVersion.minorRev, 0x3);
	XCTAssertEqual(version->numericVersion.bugFixRev, 0x4);
	XCTAssertEqual(version->numericVersion.stage, finalStage);
	XCTAssertEqual(version->numericVersion.nonRelRev, 0x56);
	NSLog(@"%@", [ImpDehydratedResourceFork versionStringForNumericVersion:&(version->numericVersion)]);
}

@end
