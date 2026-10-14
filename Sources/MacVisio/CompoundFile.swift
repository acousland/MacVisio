import Foundation

/// Bounded MS-CFB reader and writer. The writer emits v3 files with FAT, mini-FAT
/// and DIFAT allocation and a root-directory red/black tree of named streams.
/// Specification: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/
struct CompoundFile {
    static let signature = Data([0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1])
    static let free:UInt32 = 0xFFFFFFFF,end:UInt32 = 0xFFFFFFFE,fatSector:UInt32 = 0xFFFFFFFD,difatSector:UInt32 = 0xFFFFFFFC
    static let limit = 128*1024*1024
    var streams:[String:Data]
    var rootClassID:Data = Data(repeating:0,count:16)

    static func read(_ data:Data) throws -> CompoundFile {
        guard data.count >= 1536,data.count <= limit,data.prefix(8) == signature else { throw DiagramError.invalid("Invalid or oversized compound document.") }
        let bytes = BinaryBytes(data)
        let version = try bytes.u16(26),shift = try bytes.u16(30)
        guard try bytes.u16(28) == 0xFFFE,(version == 3 && shift == 9 || version == 4 && shift == 12),try bytes.u16(32) == 6,try bytes.u32(56) == 4096 else { throw DiagramError.invalid("Unsupported compound document header.") }
        let sectorSize = 1 << Int(shift),sectorCount = data.count/sectorSize-1
        guard data.count % sectorSize == 0,sectorCount > 0 else { throw DiagramError.invalid("Truncated compound document sectors.") }
        func sector(_ id:UInt32) throws -> Data {
            guard Int(id)<sectorCount else { throw DiagramError.invalid("A compound document sector is outside the file.") }
            let start = (Int(id)+1)*sectorSize;return data.subdata(in:start..<start+sectorSize)
        }
        func words(_ data:Data) throws -> [UInt32] { let b = BinaryBytes(data);return try stride(from:0,to:data.count,by:4).map{try b.u32($0)} }
        let fatCount = Int(try bytes.u32(44)),difatCount = Int(try bytes.u32(72))
        guard fatCount>0,fatCount<=sectorCount,difatCount<=sectorCount else { throw DiagramError.invalid("Invalid compound allocation table sizes.") }
        var fatIDs = try (0..<109).map{try bytes.u32(76+$0*4)}.filter{$0 != free}
        var difat = try bytes.u32(68),seenDIFAT = Set<UInt32>()
        for _ in 0..<difatCount {
            guard seenDIFAT.insert(difat).inserted else { throw DiagramError.invalid("Cyclic compound DIFAT.") }
            let items = try words(sector(difat));fatIDs += items.dropLast().filter{$0 != free};difat = items.last!
        }
        guard fatIDs.count == fatCount,Set(fatIDs).count == fatIDs.count else { throw DiagramError.invalid("Invalid compound FAT references.") }
        var fat:[UInt32] = []
        for id in fatIDs { fat += try words(sector(id)) }
        guard fat.count >= sectorCount else { throw DiagramError.invalid("Incomplete compound FAT.") }
        func chain(_ start:UInt32,size:Int? = nil,maxBytes:Int = limit) throws -> Data {
            if size == 0 { return Data() }
            guard size.map({$0>=0 && $0<=maxBytes}) ?? true else { throw DiagramError.invalid("Oversized compound stream.") }
            var id = start,result = Data(),seen = Set<UInt32>()
            while id != end {
                guard Int(id)<sectorCount,seen.insert(id).inserted,result.count<=maxBytes-sectorSize else { throw DiagramError.invalid("Invalid or cyclic compound sector chain.") }
                result.append(try sector(id));id = fat[Int(id)]
                if let size = size,result.count>=size {
                    guard id == end else { throw DiagramError.invalid("A compound stream has excess allocation.") };break
                }
            }
            if let size = size { guard result.count >= size else { throw DiagramError.invalid("Truncated compound stream.") };return result.prefix(size) };return result
        }
        let directory = try chain(bytes.u32(48),maxBytes:2*1024*1024),db = BinaryBytes(directory)
        struct Entry { var name:String;var type:UInt8;var left:UInt32;var right:UInt32;var child:UInt32;var start:UInt32;var size:Int }
        var entries:[Entry] = []
        for at in stride(from:0,to:directory.count,by:128) {
            let type = try db.u8(at+66)
            if type == 0 { entries.append(Entry(name:"",type:0,left:free,right:free,child:free,start:end,size:0));continue }
            let length = Int(try db.u16(at+64)),size = try db.u64(at+120)
            guard length>=2,length<=64,length%2 == 0,size<=UInt64(limit),let name = String(data:directory.subdata(in:at..<at+length-2),encoding:.utf16LittleEndian),try db.u16(at+length-2) == 0 else { throw DiagramError.invalid("Invalid compound directory entry.") }
            entries.append(Entry(name:name,type:type,left:try db.u32(at+68),right:try db.u32(at+72),child:try db.u32(at+76),start:try db.u32(at+116),size:Int(size)))
        }
        guard let root = entries.first,root.type == 5 else { throw DiagramError.invalid("The compound document has no root entry.") }
        let miniCount = Int(try bytes.u32(64));guard miniCount<=sectorCount else { throw DiagramError.invalid("Invalid mini-FAT count.") }
        let miniFAT = miniCount == 0 ? [] : try words(chain(bytes.u32(60),size:miniCount*sectorSize))
        let miniStream = try chain(root.start,size:root.size)
        func stream(_ entry:Entry) throws -> Data {
            if entry.size>=4096 { return try chain(entry.start,size:entry.size) };if entry.size == 0 { return Data() }
            var id = entry.start,seen = Set<UInt32>(),out = Data()
            while out.count<entry.size {
                guard Int(id)<miniFAT.count,seen.insert(id).inserted,Int(id)<miniStream.count/64 else { throw DiagramError.invalid("Invalid compound mini-stream allocation.") }
                let at = Int(id)*64;out.append(miniStream.subdata(in:at..<at+64));id = miniFAT[Int(id)]
            }
            guard id == end else { throw DiagramError.invalid("A compound mini-stream has excess allocation.") };return out.prefix(entry.size)
        }
        var streams:[String:Data] = [:],visited = Set<UInt32>(),total = 0
        func walk(_ id:UInt32,path:String,depth:Int = 0) throws {
            if id == free { return }
            guard Int(id)<entries.count,visited.insert(id).inserted,depth<128,visited.count<=16384 else { throw DiagramError.invalid("Invalid compound directory tree.") }
            let entry = entries[Int(id)];guard entry.type == 1 || entry.type == 2,!entry.name.isEmpty,!entry.name.contains("/") else { throw DiagramError.invalid("Invalid compound storage entry.") }
            try walk(entry.left,path:path,depth:depth+1)
            let name = path+entry.name
            if entry.type == 2 {
                guard streams[name] == nil,total<=limit-entry.size else { throw DiagramError.invalid("Duplicate or oversized compound streams.") }
                streams[name] = try stream(entry);total += entry.size
            } else { try walk(entry.child,path:name+"/",depth:depth+1) }
            try walk(entry.right,path:path,depth:depth+1)
        }
        try walk(root.child,path:"")
        return CompoundFile(streams:streams,rootClassID:directory.subdata(in:80..<96))
    }

    func encoded() throws -> Data {
        guard streams.count<=4096,rootClassID.count == 16,streams.values.reduce(0,{$0+$1.count})<=Self.limit else { throw DiagramError.invalid("Oversized compound document.") }
        let names = streams.keys.sorted { a,b in a.utf16.count == b.utf16.count ? a.uppercased()<b.uppercased() : a.utf16.count<b.utf16.count }
        var canonical = Set<String>()
        for name in names { guard !name.isEmpty,name.utf16.count<=31,!name.contains(where:{"/\\:!\0".contains($0)}),canonical.insert(name.uppercased()).inserted else { throw DiagramError.invalid("Invalid or duplicate compound stream names.") } }
        var body = Data(),fat:[UInt32] = [],mini = Data(),miniFAT:[UInt32] = [],locations:[String:(UInt32,Int)] = [:]
        func allocate(_ bytes:Data) -> UInt32 {
            if bytes.isEmpty { return Self.end }
            let first = UInt32(body.count/512),count = (bytes.count+511)/512
            body.append(bytes);body.append(Data(repeating:0,count:count*512-bytes.count))
            for i in 0..<count { fat.append(i == count-1 ? Self.end : first+UInt32(i+1)) };return first
        }
        for name in names {
            let bytes = streams[name]!
            if bytes.isEmpty { locations[name] = (Self.end,0) }
            else if bytes.count>=4096 { locations[name] = (allocate(bytes),bytes.count) }
            else {
                let start = UInt32(mini.count/64),count = (bytes.count+63)/64
                mini.append(bytes);mini.append(Data(repeating:0,count:count*64-bytes.count))
                for i in 0..<count { miniFAT.append(i == count-1 ? Self.end : start+UInt32(i+1)) };locations[name] = (start,bytes.count)
            }
        }
        let miniStart = allocate(mini)
        var mf = Data();for item in miniFAT { mf.put(item) };if !mf.isEmpty { while mf.count%512 != 0 { mf.put(Self.free) } }
        let miniFATStart = allocate(mf)
        var left = [UInt32](repeating:Self.free,count:names.count),right = left,depths = [Int](repeating:0,count:names.count)
        func tree(_ range:Range<Int>,depth:Int) -> UInt32 {
            if range.isEmpty { return Self.free };let i = (range.lowerBound+range.upperBound)/2;depths[i] = depth
            left[i] = tree(range.lowerBound..<i,depth:depth+1);right[i] = tree(i+1..<range.upperBound,depth:depth+1);return UInt32(i+1)
        }
        let child = tree(0..<names.count,depth:0),deepest = depths.max() ?? 0
        func entry(_ name:String,type:UInt8,start:UInt32,size:Int,left:UInt32 = Self.free,right:UInt32 = Self.free,child:UInt32 = Self.free,color:UInt8 = 1,classID:Data = Data(repeating:0,count:16)) -> Data {
            var out = Data(name.utf16.flatMap{[UInt8($0&255),UInt8($0>>8)]});out.put(UInt16(0));let length = out.count;out.append(Data(repeating:0,count:64-out.count))
            out.put(UInt16(length));out.put(type);out.put(color);out.put(left);out.put(right);out.put(child);out.append(classID);out.put(UInt32(0));out.put(UInt64(0));out.put(UInt64(0));out.put(start);out.put(UInt64(size));return out
        }
        var directory = entry("Root Entry",type:5,start:miniStart,size:mini.count,child:child,classID:rootClassID)
        for (i,name) in names.enumerated() { let location = locations[name]!;directory.append(entry(name,type:2,start:location.0,size:location.1,left:left[i],right:right[i],color:depths[i] == deepest && deepest>0 ? 0 : 1)) }
        while directory.count%512 != 0 { var empty = Data(repeating:0,count:128);empty.set(Self.free,at:68);empty.set(Self.free,at:72);empty.set(Self.free,at:76);directory.append(empty) }
        let directoryStart = allocate(directory),contentCount = fat.count
        var fatCount = 1,difatCount = 0
        while true {
            let nextFAT = (contentCount+fatCount+difatCount+127)/128,nextDIFAT = fatCount>109 ? (fatCount-109+126)/127 : 0
            if nextFAT == fatCount && nextDIFAT == difatCount { break };fatCount = nextFAT;difatCount = nextDIFAT
        }
        guard body.count+(fatCount+difatCount+1)*512<=Self.limit else { throw DiagramError.invalid("Compound file exceeds the supported size.") }
        let fatIDs = (0..<fatCount).map{UInt32(contentCount+$0)},difatIDs = (0..<difatCount).map{UInt32(contentCount+fatCount+$0)}
        fat.append(contentsOf:repeatElement(Self.fatSector,count:fatCount));fat.append(contentsOf:repeatElement(Self.difatSector,count:difatCount))
        while fat.count<fatCount*128 { fat.append(Self.free) };for item in fat { body.put(item) }
        for i in 0..<difatCount {
            for j in 0..<127 { let at = 109+i*127+j;body.put(at<fatIDs.count ? fatIDs[at] : Self.free) };body.put(i+1<difatCount ? difatIDs[i+1] : Self.end)
        }
        var header = Self.signature;header.append(Data(repeating:0,count:16));header.put(UInt16(0x3E));header.put(UInt16(3));header.put(UInt16(0xFFFE));header.put(UInt16(9));header.put(UInt16(6));header.append(Data(repeating:0,count:6))
        header.put(UInt32(0));header.put(UInt32(fatCount));header.put(directoryStart);header.put(UInt32(0));header.put(UInt32(4096));header.put(miniFATStart);header.put(UInt32(mf.count/512));header.put(difatIDs.first ?? Self.end);header.put(UInt32(difatCount))
        for i in 0..<109 { header.put(i<fatIDs.count ? fatIDs[i] : Self.free) };header.append(body);return header
    }
}

struct BinaryBytes {
    let data:Data
    init(_ data:Data) { self.data = data }
    func uint(_ at:Int,_ size:Int) throws -> UInt64 {
        guard at>=0,at<=data.count-size else { throw DiagramError.invalid("Truncated binary document field.") }
        var result:UInt64 = 0;for i in 0..<size { result |= UInt64(data[data.startIndex+at+i]) << (i*8) };return result
    }
    func u8(_ at:Int) throws -> UInt8 { UInt8(try uint(at,1)) }
    func u16(_ at:Int) throws -> UInt16 { UInt16(try uint(at,2)) }
    func u32(_ at:Int) throws -> UInt32 { UInt32(try uint(at,4)) }
    func u64(_ at:Int) throws -> UInt64 { try uint(at,8) }
    func double(_ at:Int) throws -> Double { Double(bitPattern:try u64(at)) }
}
extension Data {
    mutating func put<T:FixedWidthInteger>(_ value:T) { var little = value.littleEndian;Swift.withUnsafeBytes(of:&little){append(contentsOf:$0)} }
    mutating func putDouble(_ value:Double) { put(value.bitPattern) }
    mutating func set<T:FixedWidthInteger>(_ value:T,at:Int) { var little = value.littleEndian;Swift.withUnsafeBytes(of:&little){replaceSubrange(at..<at+MemoryLayout<T>.size,with:$0)} }
}
