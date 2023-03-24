//
//  TestCSVProducer.m
//  UnitTests
//
//  Created by Peter Hosey on 2023-03-23.
//

#import <XCTest/XCTest.h>

#import "ImpCSVProducer.h"

@interface TestCSVProducer : XCTestCase

@end

@implementation TestCSVProducer
{
	ImpCSVProducer *_Nonnull csvProducer;
}

- (void) setUp {
	csvProducer = [[ImpCSVProducer alloc] initForTestingPurposesWithHeaderRow:@[ @"name", @"data_length", @"rsrc_length", @"data_md5", @"rsrc_md5" ]];
}

- (void) tearDown {
}

- (void) testCSVNoRows {
	XCTAssertNotNil(csvProducer.lastRowWritten);
}

- (void) testCSVSimpleRow {
	NSString *_Nonnull const headerRow = csvProducer.lastRowWritten;
	XCTAssertNotNil(headerRow);

	NSString *_Nonnull const md5OfEmpty = @"d41d8cd98f00b204e9800998ecf8427e";
	NSString *_Nonnull const md5OfOneLF = @"68b329da9893e34099c7d8ad5cb9c940";
	NSArray <NSString *> *_Nonnull const simpleRow = @[ @"Test.txt", @"0", @"1", md5OfEmpty, md5OfOneLF ];
	[csvProducer writeRow:simpleRow];

	NSString *_Nonnull const dataRow = csvProducer.lastRowWritten;
	XCTAssertNotNil(dataRow);
	NSString *_Nonnull const naivelyJoinedDataRow = [[simpleRow componentsJoinedByString:@","] stringByAppendingString:@"\x0d\x0a"];
	XCTAssertEqualObjects(dataRow, naivelyJoinedDataRow);
}

- (void) testCSVRowWithItemContainingComma {
	NSString *_Nonnull const headerRow = csvProducer.lastRowWritten;
	XCTAssertNotNil(headerRow);

	NSString *_Nonnull const md5OfEmpty = @"d41d8cd98f00b204e9800998ecf8427e";
	NSString *_Nonnull const md5OfOneLF = @"68b329da9893e34099c7d8ad5cb9c940";
	NSArray <NSString *> *_Nonnull const notSoSimpleRow = @[ @"Test 1,2,3.txt", @"0", @"1", md5OfEmpty, md5OfOneLF ];
	[csvProducer writeRow:notSoSimpleRow];

	NSString *_Nonnull const dataRow = csvProducer.lastRowWritten;
	XCTAssertNotNil(dataRow);
	XCTAssertNotEqualObjects(dataRow, headerRow);
	NSString *_Nonnull const naivelyJoinedDataRow = [[notSoSimpleRow componentsJoinedByString:@","] stringByAppendingString:@"\x0d\x0a"];
	XCTAssertNotEqualObjects(dataRow, naivelyJoinedDataRow);
	XCTAssertTrue([dataRow hasPrefix:@"\""]);
	XCTAssertTrue([dataRow containsString:@"\","]);
}

- (void) testCSVRowWithItemContainingDoubleQuote {
	NSString *_Nonnull const headerRow = csvProducer.lastRowWritten;
	XCTAssertNotNil(headerRow);

	NSString *_Nonnull const md5OfEmpty = @"d41d8cd98f00b204e9800998ecf8427e";
	NSString *_Nonnull const md5OfOneLF = @"68b329da9893e34099c7d8ad5cb9c940";
	NSArray <NSString *> *_Nonnull const notSoSimpleRow = @[ @"Test \"1-2-3\".txt", @"0", @"1", md5OfEmpty, md5OfOneLF ];
	[csvProducer writeRow:notSoSimpleRow];

	NSString *_Nonnull const dataRow = csvProducer.lastRowWritten;
	XCTAssertNotNil(dataRow);
	XCTAssertNotEqualObjects(dataRow, headerRow);
	NSString *_Nonnull const naivelyJoinedDataRow = [[notSoSimpleRow componentsJoinedByString:@","] stringByAppendingString:@"\x0d\x0a"];
	XCTAssertNotEqualObjects(dataRow, naivelyJoinedDataRow);
	XCTAssertTrue([dataRow hasPrefix:@"\""]);
	XCTAssertTrue([dataRow containsString:@"\"\""]);
	XCTAssertTrue([dataRow containsString:@"\","]);
}

@end
