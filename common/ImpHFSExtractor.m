//
//  ImpHFSExtractor.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import "ImpHFSExtractor.h"

#import "ImpHFSVolume.h"
#import "ImpVolumeProbe.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpDehydratedItem.h"
#import "ImpSizeUtilities.h"

@implementation ImpHFSExtractor

- (void) deliverProgressUpdate:(double)progress
	operationDescription:(NSString *_Nonnull)operationDescription
{
	if (self.extractionProgressUpdateBlock != nil) {
		self.extractionProgressUpdateBlock(progress, operationDescription);
	}
}

- (bool) isHFSPath:(NSString *_Nonnull const) maybePath {
	return [maybePath containsString:@":"];
}

///Parse an HFS-style (colon-separated) path string and return the components in order as an array of strings. TN1041 gives the rules for parsing pathnames. If the path is relative (begins with a colon), the returned array will begin with an empty string. (In our case, it probably makes the most sense to consider the path relative to the volume.) Returns nil if the pathname is invalid (e.g., too many consecutive colons).
- (NSArray <NSString *> *_Nullable const) parseHFSPath:(NSString *_Nonnull const)hfsPathString {
	//As a rough heuristic, assume filenames average 8 characters long and preallocate that much space.
	NSMutableArray *_Nonnull const path = [NSMutableArray arrayWithCapacity:ImpCeilingDivide(hfsPathString.length, 8)];

	@autoreleasepool {
		//Ignore a single trailing colon (by pruning it off before we feed the string to the scanner).
		NSString *_Nonnull const trimmedString = [hfsPathString hasSuffix:@":"] ? [hfsPathString substringToIndex:hfsPathString.length - 1] : hfsPathString;

		NSScanner *_Nonnull const scanner = [NSScanner scannerWithString:trimmedString];
		//Don't skip any characters—we want 'em all.
		scanner.charactersToBeSkipped = [NSCharacterSet characterSetWithRange:(NSRange){ 0, 0 }];

		bool const isRelativePath = [scanner scanString:@":" intoString:NULL];
		if (isRelativePath)
			[path addObject:@""];

		while (! scanner.isAtEnd) {
			NSString *_Nullable filename = nil;
			bool const gotAFilename = [scanner scanUpToString:@":" intoString:&filename];
			if (gotAFilename) {
				[path addObject:filename];
			} else {
				//Empty string. If we have any path components, pop one off—consecutive colons is the equivalent of “..” in POSIX paths. If we've run out of path components, this pathname is invalid.
				if (path.count > 0) {
					[path removeLastObject];
				} else {
					return nil;
				}
			}
			[scanner scanString:@":" intoString:NULL];
		}
	}

	return path;
}

- (NSString *_Nonnull const) quarryName {
	return [self parseHFSPath:self.quarryNameOrPath].lastObject;
}

///Return whether a quarry path from parseHFSPath: matches a given path for a catalog item. Returns true for any volume name if the first item in the quarry path is the empty string (indicating a relative path, which we interpret as relative to the volume root).
- (bool) isQuarryPath:(NSArray <NSString *> *_Nonnull const)quarryPath isEqualToCatalogPath:(NSArray <NSString *> *_Nonnull const)catalogPath {
	NSParameterAssert(catalogPath.count > 0);
	if (quarryPath.count != catalogPath.count) {
		return false;
	}
	NSEnumerator <NSString *> *_Nonnull const quarryPathEnum = [quarryPath objectEnumerator];
	NSEnumerator <NSString *> *_Nonnull const catalogPathEnum = [catalogPath objectEnumerator];

	NSString *_Nullable const quarryVolumeName = [quarryPathEnum nextObject];
	NSString *_Nullable const catalogVolumeName = [catalogPathEnum nextObject];

	if (quarryVolumeName.length == 0 || [quarryVolumeName isEqualToString:catalogVolumeName]) {
		//Step through both arrays in parallel, comparing pairs of items as we go. Bail at the first non-equal pair.
		NSString *_Nullable quarryItemName = [quarryPathEnum nextObject], *_Nullable catalogItemName = [catalogPathEnum nextObject];
		while (quarryItemName != nil && catalogItemName != nil && [quarryItemName isEqualToString:catalogItemName]) {
			quarryItemName = [quarryPathEnum nextObject];
			catalogItemName = [catalogPathEnum nextObject];
		}

		//If we have indeed made it to the end of both arrays, then all items were equal.
		if (quarryItemName == nil && catalogItemName == nil) {
			return true;
		}
	}
	return false;
}

- (bool)performExtractionOrReturnError:(NSError *_Nullable *_Nonnull) outError {
	__block bool rehydrated = false;

	int const readFD = open(self.sourceDevice.fileSystemRepresentation, O_RDONLY);
	if (readFD < 0) {
		NSError *_Nonnull const cantOpenForReadingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open source device for reading" }];
		if (outError != NULL) *outError = cantOpenForReadingError;
		return false;
	}

	[self deliverProgressUpdate:0.0 operationDescription:@"Finding HFS volume"];

	__block NSError *_Nullable volumeLoadError = nil;
	__block NSError *_Nullable rehydrationError = nil;

	ImpVolumeProbe *_Nonnull const probe = [[ImpVolumeProbe alloc] initWithFileDescriptor:readFD];
	[probe findVolumes:^(const u_int64_t startOffsetInBytes, const u_int64_t lengthInBytes, Class  _Nullable const __unsafe_unretained volumeClass) {
		if (volumeClass != Nil && volumeClass != [ImpHFSVolume class]) {
			//We only extract from HFS volumes. Skip.
			return;
		}

		ImpHFSVolume *_Nonnull const srcVol = [[ImpHFSVolume alloc] initWithFileDescriptor:readFD startOffsetInBytes:startOffsetInBytes lengthInBytes:lengthInBytes textEncoding:self.hfsTextEncoding];
		if (! [srcVol loadAndReturnError:&volumeLoadError])
			return;

		bool const grabEverything = (self.quarryNameOrPath == nil);
		if (grabEverything) {
			self.quarryNameOrPath = [srcVol.volumeName stringByAppendingString:@":"];
		}
		bool const grabAnyFileWithThisName = ! [self isHFSPath:self.quarryNameOrPath];
		//TODO: Possibly in need of special-casing: When parsedPath is @[ @"" ], it means the user asked for ':'. Treat this as a relative path to the root directory, and unarchive the entire root volume.
		NSArray <NSString *> *_Nonnull const parsedPath = [self parseHFSPath:self.quarryNameOrPath];

		//TODO: Need to implement the smarter destination path logic promised in the help. This requires the user to specify the destination path including filename.
		__block ImpDehydratedItem *_Nullable matchedByPath = nil;
		NSMutableSet <ImpDehydratedItem *> *_Nonnull const matchedByName = [NSMutableSet setWithCapacity:1];

		ImpBTreeFile *_Nonnull const catalog = srcVol.catalogBTree;
		[catalog walkLeafNodes:^bool(ImpBTreeNode *_Nonnull const node) {
			@autoreleasepool {
				[node forEachHFSCatalogRecord_file:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogFile *const _Nonnull fileRec) {
					ImpDehydratedItem *_Nonnull const dehydratedFile = [[ImpDehydratedItem alloc] initWithHFSVolume:srcVol catalogNodeID:L(fileRec->fileID) key:catalogKeyPtr fileRecord:fileRec];
		//				ImpPrintf(@"We're looking for “%@” and found a file named “%@”", self.quarryName, dehydratedFile.name);
					bool const nameIsEqual = [dehydratedFile.name isEqualToString:self.quarryName];
					bool const shouldRehydrateBecauseName = (grabAnyFileWithThisName && nameIsEqual);
					bool const shouldRehydrateBecausePath = [self isQuarryPath:parsedPath isEqualToCatalogPath:dehydratedFile.path];
					if (shouldRehydrateBecauseName) {
						[matchedByName addObject:dehydratedFile];
					}
					if (shouldRehydrateBecausePath) {
						matchedByPath = dehydratedFile;
					}
				} folder:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogFolder *const _Nonnull folderRec) {
					ImpDehydratedItem *_Nonnull const dehydratedFolder = [[ImpDehydratedItem alloc] initWithHFSVolume:srcVol catalogNodeID:L(folderRec->folderID) key:catalogKeyPtr folderRecord:folderRec];
		//				ImpPrintf(@"We're looking for “%@” and found a file named “%@”", self.quarryName, dehydratedFile.name);
					bool const nameIsEqual = [dehydratedFolder.name isEqualToString:self.quarryName];
					bool const shouldRehydrateBecauseName = (grabAnyFileWithThisName && nameIsEqual);
					bool const shouldRehydrateBecausePath = [self isQuarryPath:parsedPath isEqualToCatalogPath:dehydratedFolder.path];
					if (shouldRehydrateBecauseName) {
						[matchedByName addObject:dehydratedFolder];
					}
					if (shouldRehydrateBecausePath) {
						matchedByPath = dehydratedFolder;
					}
				} thread:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogThread *const _Nonnull threadRec) {
					//Ignore thread records.
				}];
			}

			return true;
		}];

		NSMutableArray <ImpDehydratedItem *> *_Nonnull const matches = [NSMutableArray arrayWithCapacity:(matchedByPath != nil) + matchedByName.count];
		if (matchedByPath != nil) [matches addObject:matchedByPath];
		[matches addObjectsFromArray:matchedByName.allObjects];

		if (matches.count == 0) {
			ImpPrintf(@"No such item found.");
		} else if (matches.count > 1) {
			ImpPrintf(@"Multiple matches found:");
			for (ImpDehydratedItem *_Nonnull const item in matches) {
				ImpPrintf(@"- %@", [item.path componentsJoinedByString:@":"]);
			}
		} else {
			ImpDehydratedItem *_Nonnull const item = matches.firstObject;
	//		ImpPrintf(@"Found an item named %@ with parent item #%u", item.name, item.parentFolderID);
			NSString *_Nonnull const destPath = self.destinationPath ?: [item.name stringByReplacingOccurrencesOfString:@"/" withString:@":"];
			rehydrated = [item rehydrateAtRealWorldURL:[NSURL fileURLWithPath:destPath isDirectory:false] error:&rehydrationError];
			if (! rehydrated) {
				ImpPrintf(@"Failed to rehydrate file named %@: %@", item.name, rehydrationError);
			} else {
				[self deliverProgressUpdate:1.0 operationDescription:@"Extraction complete."];
			}
		}
	}];

	if (! rehydrated) {
		if (outError != NULL) {
			*outError = volumeLoadError ?: rehydrationError;
		}
	}

	return rehydrated;
}

@end
