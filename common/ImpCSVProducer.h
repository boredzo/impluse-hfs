//
//  ImpCSVProducer.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-03-23.
//

#import <Foundation/Foundation.h>

@interface ImpCSVProducer : NSObject

///Create a new CSV producer with a row of one or more columns names. This row will be the first row of output, and future rows will be checked for length against this header row.
- (instancetype _Nonnull) initWithFileHandle:(NSFileHandle *_Nonnull const)outputFH headerRow:(NSArray <NSString *> *_Nonnull const)headerRow;

///For the unit tests.
- (instancetype _Nonnull) initForTestingPurposesWithHeaderRow:(NSArray <NSString *> *_Nonnull const)headerRow;

///Throws if row.count does not match headerRow.count (see initWithFileHandle:headerRow:).
- (void) writeRow:(NSArray <NSString *> *_Nonnull const)row;

///Exposed for testing purposes. Before any data rows have been written, this is the header row.
@property(readonly, copy) NSString *_Nonnull lastRowWritten;

@end
