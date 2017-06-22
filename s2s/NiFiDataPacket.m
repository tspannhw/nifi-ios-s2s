/*
 * Copyright 2017 Hortonworks, Inc.
 * All rights reserved.
 *
 *   Hortonworks, Inc. licenses this file to you under the Apache License, Version 2.0
 *   (the "License"); you may not use this file except in compliance with
 *   the License. You may obtain a copy of the License at
 *   http://www.apache.org/licenses/LICENSE-2.0
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 *
 * See the associated NOTICE file for additional information regarding copyright ownership.
 */

#import <Foundation/Foundation.h>
#import <zlib.h>
#import "NiFiSiteToSiteClientPrivate.h"

/********** NiFiDataPacket Class Cluster Implementation **********/

@interface NiFiDataPacket()
@property (nonatomic, retain, readwrite, nonnull) NSDictionary<NSString *, NSString *> *attributes;
@end


@interface NiFiStreamingDataPacket : NiFiDataPacket
@property (nonatomic, retain, readwrite, nonnull) NSInputStream *dataStream;
@property (nonatomic, readwrite) NSUInteger dataLength;
- (nonnull instancetype)initWithAttributes:(nonnull NSDictionary<NSString *,NSString *> *)attributes
                                dataStream:(nonnull NSInputStream *)dataStream
                                dataLength:(NSUInteger)dataLength;
@end


@interface NiFiBytesDataPacket : NiFiDataPacket
@property (nonatomic, retain, readwrite, nonnull) NSData *data;
- (nonnull instancetype)initWithAttributes:(nonnull NSDictionary<NSString *,NSString *> *)attributes
                                      data:(nonnull NSData *)data;
@end


@implementation NiFiDataPacket

// factory methods are supposed to validate that the init will work, and if it won't, then return nil
+ (nonnull instancetype)dataPacketWithAttributes:(nonnull NSDictionary<NSString *,NSString *> *)attributes
                                            data:(nonnull NSData *)data {
    return [[NiFiBytesDataPacket alloc] initWithAttributes:attributes data:data];
}

+ (nonnull instancetype)dataPacketWithAttributes:(nonnull NSDictionary<NSString *,NSString *> *)attributes
                                      dataStream:(nonnull NSInputStream *)dataStream
                                      dataLength:(NSUInteger)length {
    return [[NiFiStreamingDataPacket alloc] initWithAttributes:attributes
                                                    dataStream:dataStream
                                                    dataLength:length];
}

+ (nonnull instancetype)dataPacketWithString:(nonnull NSString *)string {
    return [NiFiBytesDataPacket dataPacketWithAttributes:[NSDictionary dictionary]
                                                    data:[string dataUsingEncoding:NSUTF8StringEncoding]];
}

- (nonnull instancetype)initWithAttributes:(nonnull NSDictionary<NSString *, NSString *> *)attributes {
    self = [super init];
    if(self != nil) {
        _attributes = attributes;
    }
    return self;
}

- (nonnull NSData *)data {
    @throw [NSException
            exceptionWithName:NSInternalInconsistencyException
            reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
            userInfo:nil];
}

- (nonnull NSInputStream *)dataStream {
    @throw [NSException
            exceptionWithName:NSInternalInconsistencyException
            reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
            userInfo:nil];
}

- (NSUInteger)dataLength {
    @throw [NSException
            exceptionWithName:NSInternalInconsistencyException
            reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
            userInfo:nil];
}

@end


@implementation NiFiStreamingDataPacket

- (nonnull instancetype)initWithAttributes:(nonnull NSDictionary<NSString *,NSString *> *)attributes
                                dataStream:(nonnull NSInputStream *)dataStream
                                dataLength:(NSUInteger)dataLength {
    self = [super initWithAttributes:attributes];
    if(self != nil) {
        _dataStream = dataStream;
        _dataLength = dataLength;
    }
    return self;
}

- (nonnull NSData *)data {
    size_t bufsize = MIN(1024U, _dataLength);
    uint8_t *buf = malloc(bufsize);
    if (buf == NULL) {
        return nil;
    }
    
    NSMutableData* result = [NSMutableData dataWithCapacity:_dataLength];
    @try {
        while (true) {
            NSInteger n = [_dataStream read:buf maxLength:bufsize];
            if (n < 0) {
                result = nil;
                break;
            }
            else if (n == 0) {
                break;
            }
            else {
                [result appendBytes:buf length:n];
            }
        }
    }
    @catch (NSException * exn) {
        result = nil;
    }
    free(buf);
    return result;
}

- (nonnull NSInputStream *)dataStream {
    return _dataStream;
}

- (NSUInteger)dataLength {
    return _dataLength;
}

@end


@implementation NiFiBytesDataPacket

- (nonnull instancetype)initWithAttributes:(nonnull NSDictionary<NSString *,NSString *> *)attributes
                                            data:(nonnull NSData *)data {
    self = [super initWithAttributes:attributes];
    if(self != nil) {
        _data = data;
    }
    return self;
}

- (nonnull NSData *)data {
    return _data;
}

- (nonnull NSInputStream *)dataStream {
    return [NSInputStream inputStreamWithData:_data];
}

- (NSUInteger)dataLength {
    return _data.length;
}

@end


/********** DataPacketWriter/Encoder Implementations **********/

@interface NiFiDataPacketEncoder()
@property (nonatomic, retain, nonnull) NSMutableData * encodedData;
@property (nonatomic) NSUInteger dataPacketCount;
@end

@implementation NiFiDataPacketEncoder

- (nonnull instancetype) init {
    self = [super init];
    if(self != nil) {
        _encodedData = [[NSMutableData alloc] init];
        _dataPacketCount = 0;
    }
    return self;
}

- (void) appendDataPacket:(nonnull NiFiDataPacket *)dataPacket {
    // Append number of data packet attributes that will follow
    int32_t attributeCount = (int32_t)dataPacket.attributes.count;
    [self appendInt32:attributeCount];
    // Append each attribute as string, string
    for (NSString * key in dataPacket.attributes) {
        NSString * value = [dataPacket.attributes objectForKey:key];
        [self appendString:key];
        [self appendString:value];
    }
    // Append size of data packet content that will follow
    [self appendInt64:[dataPacket dataLength]];
    // Append data packet content
    [_encodedData appendData:[dataPacket data]];
    
    _dataPacketCount++;
}

- (void) appendInt32:(uint32_t)value {
    uint32_t wireValue = CFSwapInt32HostToBig(value); // convert to network order if necessary
    [_encodedData appendBytes:&wireValue length:4];
}

- (void) appendInt64:(int64_t)value {
    uint64_t wireValue = CFSwapInt64HostToBig(value); // convert to network order if necessary
    [_encodedData appendBytes:&wireValue length:8];
}

- (void) appendString:(NSString *)value {
    int32_t length = (int32_t)value.length;
    [self appendInt32:length];
    [_encodedData appendBytes:[value UTF8String] length:length];
}

- (nonnull NSData *)getEncodedData {
    return _encodedData;
}

- (nonnull NSInputStream *)getEncodedDataStream {
    return [NSInputStream inputStreamWithData:_encodedData];
}

- (NSUInteger)getDataPacketCount {
    return _dataPacketCount;
}

- (NSUInteger)getEncodedDataCrcChecksum {
    NSUInteger crcChecksum = crc32(0, _encodedData.bytes, (uint)_encodedData.length);
    return crcChecksum;
}

- (NSUInteger)getEncodedDataByteLength {
    return _encodedData.length;
}

@end
