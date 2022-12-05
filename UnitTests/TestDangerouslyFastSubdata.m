//
//  TestDangerouslyFastSubdata.m
//  UnitTests
//
//  Created by Peter Hosey on 2022-12-04.
//

#import <XCTest/XCTest.h>

#import "NSData+ImpSubdata.h"

@interface TestDangerouslyFastSubdata : XCTestCase

@end

@implementation TestDangerouslyFastSubdata
{
	NSData *_parentData;
	NSRange _wholeRange;
	NSRange _middleRange;
}

- (void)setUp {
	enum { chunkLength = 6 };
	_parentData = [@"DEEEEF" @"xyyyyz" @"GHHHHI" dataUsingEncoding:NSUTF8StringEncoding];
	_wholeRange = (NSRange){ .location = 0, .length = _parentData.length };
	_middleRange = (NSRange){ .location = chunkLength * 1, .length = chunkLength * 1 };
}

- (void)tearDown {
	_parentData = nil;
}

- (void)testWholeSubdata {
	NSData *_Nonnull const subdata = [_parentData dangerouslyFastSubdataWithRange_Imp:_wholeRange];
	char const *_Nonnull const bytes = subdata.bytes;
	XCTAssertEqual(bytes[0], 'D', @"Subdata was misaligned; got wrong character '%c'", bytes[0]);
	XCTAssertEqual(bytes[_wholeRange.length - 1], 'I', @"Subdata was misaligned; got wrong character '%c'", bytes[_wholeRange.length - 1]);
}

- (void)testMiddleSubdata {
	NSData *_Nonnull const subdata = [_parentData dangerouslyFastSubdataWithRange_Imp:_middleRange];
	char const *_Nonnull const bytes = subdata.bytes;
	XCTAssertEqual(bytes[0], 'x', @"Subdata was misaligned; got wrong character '%c'", bytes[0]);
	XCTAssertEqual(bytes[_middleRange.length - 1], 'z', @"Subdata was misaligned; got wrong character '%c'", bytes[_middleRange.length - 1]);
}

@end
