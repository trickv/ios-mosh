/// Errors thrown by MoshWire (protobuf syntax errors are `ProtoError`).
///
/// Where mosh would `assert` and abort on the same input, this library throws instead, so that a
/// client can drop the datagram and carry on. All of these concern data that has already passed
/// authentication, so a correct server never causes them.
public enum WireError: Error, Equatable, Sendable {
    /// A decrypted datagram is too short to hold the two timestamps (4 bytes).
    /// mosh: `dos_assert( message.text.size() >= 2 * sizeof( uint16_t ) )`.
    case packetTooShort(Int)
    /// A packet payload is too short to hold a fragment header (10 bytes).
    /// mosh: `fatal_assert( x.size() >= frag_header_len )`.
    case fragmentTooShort(Int)
    /// A fragment number above 0x7FFF. The top bit of the 16-bit field is the "final" flag.
    /// mosh: `fatal_assert( !( fragment_num & 0x8000 ) )`.
    case fragmentNumberOutOfRange(Int)
    /// The space for fragment contents is below one byte.
    case fragmentBudgetTooSmall(Int)
    /// The instruction does not fit in 32768 fragments of the given size.
    case tooManyFragments(Int)
    /// An instruction (before compression) is larger than mosh's 4 MiB buffer: no peer could
    /// expand it again.
    case instructionTooLarge(Int)
    /// zlib `compress` failed with this status.
    case compressionFailed(Int32)
    /// zlib `uncompress` failed with this status: damaged data, or more than 4 MiB when expanded.
    case decompressionFailed(Int32)
    /// A fragment arrived twice under one instruction id with different content.
    /// mosh: `assert( fragments.at( frag.fragment_num ) == frag )`.
    case conflictingFragment(id: UInt64, fragmentNum: UInt16)
    /// A fragment contradicts what is already held for its instruction id: a final fragment
    /// numbered below a fragment already held, or more fragments than the final one allows.
    /// mosh: `assert( (int)fragments.size() <= fragments_total )`,
    /// `assert( fragments_arrived <= fragments_total )`.
    case fragmentOutOfRange(id: UInt64, fragmentNum: UInt16)
    /// The assembly was read before every fragment had arrived.
    /// mosh: `assert( fragments_arrived == fragments_total )`, `assert( fragments.at( i ).initialized )`.
    case assemblyIncomplete
}
