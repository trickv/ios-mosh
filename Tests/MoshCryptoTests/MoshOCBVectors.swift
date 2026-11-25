// Mosh: the mobile shell
// Copyright 2012 Keith Winstein
// SPDX-License-Identifier: GPL-3.0-or-later
// Ported to Swift in 2026 from mosh 1.4.0 (the mosh source is named below). The
// OpenSSL linking exception of the original is not carried over: this port links no OpenSSL.

// Generated once from mosh 1.4.0 src/tests/ocb-aes.cc (test_all_vectors) by a throwaway script.
// Do not edit by hand. Order and content are those of the C source.
// Fields: key, nonce, associated data, plaintext, ciphertext with tag. All hex.

struct OCBVector {
    let key: String
    let nonce: String
    let associatedData: String
    let plaintext: String
    let ciphertext: String
}

/// The 21 vectors of mosh's ocb-aes.cc: 19 from draft-krovetz-ocb-03 appendix A, then two long
/// regression texts.
let moshOCBVectors: [OCBVector] = [
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "",
        plaintext: "",
        ciphertext: "197b9c3c441d3c83eafb2bef633b9182"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "0001020304050607",
        plaintext: "0001020304050607",
        ciphertext: "92b657130a74b85a16dc76a46d47e1ead537209e8a96d14e"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "0001020304050607",
        plaintext: "",
        ciphertext: "98b91552c8c009185044e30a6eb2fe21"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "",
        plaintext: "0001020304050607",
        ciphertext: "92b657130a74b85a971effcae19ad4716f88e87b871fbeed"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "000102030405060708090a0b0c0d0e0f",
        plaintext: "000102030405060708090a0b0c0d0e0f",
        ciphertext: "bea5e8798dbe7110031c144da0b26122776c9924d6723a1fc4524532ac3e5beb"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "000102030405060708090a0b0c0d0e0f",
        plaintext: "",
        ciphertext: "7ddb8e6cea6814866212509619b19cc6"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "",
        plaintext: "000102030405060708090a0b0c0d0e0f",
        ciphertext: "bea5e8798dbe7110031c144da0b2612213cc8b747807121a4cbb3e4bd6b456af"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "000102030405060708090a0b0c0d0e0f1011121314151617",
        plaintext: "000102030405060708090a0b0c0d0e0f1011121314151617",
        ciphertext: """
        bea5e8798dbe7110031c144da0b26122fcfcee7a2a8d4d485fa94fc3f38820f1
        dc3f3d1fd4e55e1c
        """),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "000102030405060708090a0b0c0d0e0f1011121314151617",
        plaintext: "",
        ciphertext: "282026da3068bc9fa118681d559f10f6"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "",
        plaintext: "000102030405060708090a0b0c0d0e0f1011121314151617",
        ciphertext: """
        bea5e8798dbe7110031c144da0b26122fcfcee7a2a8d4d486ef2f52587fda0ed
        97dc7eede241df68
        """),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "000102030405060708090a0b0c0d0e0f1011121314151617",
        plaintext: "000102030405060708090a0b0c0d0e0f1011121314151617",
        ciphertext: """
        bea5e8798dbe7110031c144da0b26122fcfcee7a2a8d4d485fa94fc3f38820f1
        dc3f3d1fd4e55e1c
        """),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "000102030405060708090a0b0c0d0e0f1011121314151617",
        plaintext: "",
        ciphertext: "282026da3068bc9fa118681d559f10f6"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "",
        plaintext: "000102030405060708090a0b0c0d0e0f1011121314151617",
        ciphertext: """
        bea5e8798dbe7110031c144da0b26122fcfcee7a2a8d4d486ef2f52587fda0ed
        97dc7eede241df68
        """),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        plaintext: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        ciphertext: """
        bea5e8798dbe7110031c144da0b26122ceaab9b05df771a657149d53773463cb
        b2a040dd3bd5164372d76d7bb6824240
        """),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        plaintext: "",
        ciphertext: "e1e072633bade51a60e85951d9c42a1b"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "",
        plaintext: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        ciphertext: """
        bea5e8798dbe7110031c144da0b26122ceaab9b05df771a657149d53773463cb
        4a3bae824465cfdaf8c41fc50c7df9d9
        """),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: """
        000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
        2021222324252627
        """,
        plaintext: """
        000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
        2021222324252627
        """,
        ciphertext: """
        bea5e8798dbe7110031c144da0b26122ceaab9b05df771a657149d53773463cb
        68c65778b058a635659c623211deea0de30d2c381879f4c8
        """),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: """
        000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
        2021222324252627
        """,
        plaintext: "",
        ciphertext: "7aeb7a69a1687dd082ca27b0d9a37096"),
    OCBVector(
        key: "000102030405060708090a0b0c0d0e0f",
        nonce: "000102030405060708090a0b",
        associatedData: "",
        plaintext: """
        000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
        2021222324252627
        """,
        ciphertext: """
        bea5e8798dbe7110031c144da0b26122ceaab9b05df771a657149d53773463cb
        68c65778b058a635060c8467f4abab5e8b3c2067a2e115dc
        """),
    OCBVector(
        key: "06f89f69da49dad76848ffb360b68f00",
        nonce: "dcbf851823d9678545596fad",
        associatedData: "",
        plaintext: """
        c48e1f04102fa558684262f31be763a777896416e6b0f7fafef0b95022dcce78
        a501a42da20f50ea9aae23601cc911845fd00a8899cdf11b7cf971c2d8e37bb1
        bc91ce10daedbfa5df96697afaca9a9140f98ff1fe5a2b2117a5ae97bd0b68e0
        587ab41089de3012b714ebe8faa5877a7eead0340baf730b1ca7c5cb84155f45
        538e27d7a07daf99056e9ff4cde5a11143bd7a24a3b7b6927cb7d86f1778b330
        536e46141186f6702e258e54f8702f472bf8f6c3eefb9b7df073ad24c0e958a8
        79dc92256df39da88f07a3e7abf4bc3229b6efdb204251cfd557da14c72ab319
        de31f777958d33571deb9a80984d9507eb3842ebe0ab2df39e16fa6d06624158
        81bf3d011af7ba53ce60ef86c911ed895bcf98b4d3d4acb97169eef6a7774e46
        0ff71d7d364e8615cdf3d35caa9774cc5dd6f05c62270d4b01dd8be62c7299ba
        5b95870fb99abea2425e7d1b1908bcef66242fb3fce7dab17951e93b4566dcd8
        0fa756bf56154b15cc3e9f44b9edc20a7ca96d87cde2009f2f2cf0bc1bb027e8
        463e061ed5b6b482f788b748f358b0236dc2d3859d1fe530fcc84662d1e1ae3b
        3aa957e0d78f7e4d597d7aebbfd31000a0e47676e3a814d003bf1f6af911ce98
        2c2a862577851476d451abc73aa7e1f723f72ba3bae40ba4819a839869c31c8a
        bd261236229dce855da3a0df66d059f647f2c537f1620d0c455be5fe3c8d2875
        """,
        ciphertext: """
        a1d8a0e0755cb4f4ab596d14fc2e7554a3354f5769487a46175fd93450f935e5
        6fee27db280f060bafd5504e207835d64da018e86c5b07bbb6d03f4a0e1432af
        0d6a5db6e436b01cae2e758519539df2c6c6f5294a5d73d6cd3aec38157b1f3d
        198f7f855375fe6c8a5d4f053f165e739cbebedbe8b23eea0f2e2cf32c9c565b
        f7f2ed8707fb877409dab8ad57c0a079c6691c7908693518c454ca6bed89a027
        32191fafff121c1b08a69f0ee3019877db75df87676dd9b42339d08154f88918
        5cbdb74df4b18b372e9b20299f959edd732cdb37e57d9f8a79ff8f5b9910e1e9
        1dcb1f17ef7db7d150234a3892fbbe1cff23683ab9c8bca0aba7bec884ce66a7
        1117c648914d77e164c42608cdb4ea1042605a7c5a72bab493f702a1d444db1a
        4ac3b1ea6974ea18b35a27096f5b1f30e2eb2a375ed2e223ecbccbcb6541ed0e
        23da7145f33f7d4473d7144dab03f77d24339d25831f3df3c934426c2f61a283
        a00fb628e827f091f6c57ea17474afa77fba9929b2919ff0f7711ff00bd6d9f9
        72aa04095d75765f18c8d5d5841a403fe538e438dff90d79dc71c8a8ef864e26
        f4c246f4e064d65efb1c47583d877cbaa3f598dcd5dfaf6296ee4e39324c6dd2
        0a6ff8349876ae21a1413d96fc52dbddf39ab1f3783db82faeae7de04bb2df2b
        12aceefbf85460ea74d5de437b38455fa0b8e8cc8ae3cc0c92e6b1b0e2c199ca
        1ba1ac6e7a8aa0203deb298bf4554162
        """),
    OCBVector(
        key: "7a540d3e5638f7c6cfabf956dcca1423",
        nonce: "9b0ec115d5e6c9abe6882a18",
        associatedData: "",
        plaintext: """
        52dba7442b1c9c244df3a1e4537b9bb225c5a3814223a9b412f8fce4f68e20d4
        597b392d5d7c6eb75102907a8eaa30d0ebdf70095aecfbd4db0be91b79af40a3
        c9d13f0e7e9ba8f24ea2ae81e78fe94af88438209bcb0d9e4687cc0c71f24ce5
        5747fb521d0c92cd9bd0a3a3fe444f2a2d7dc84887718a83834352d987720a1f
        727de00de4ba382dab898534fe30e947996996373b880d085b41f0553a90b65d
        c9b8fa22eb54671b433b2a13df7671bf8fbaf65fe0ae8480d39a9efe35290c44
        b83bc8583f5118f08e3fe0feff55e1fd79ed716db9bef076254e6fa2495bec20
        61956567bfa37318657c2f94293b577d786abd222b175eda2b4ec3a5f09ad91c
        cfc4dd7e07b4e650d09daf869d3ffe706418ba3290e563a0083d1dceb2773159
        d4b4032ce2151117d1ba5e1e7d3809cf253e3d897e13ae11facd462386c578c8
        1ae88f9a9ccebe015d7056a88407072a1cd4338b2f010fd0cccd29ec736edeb2
        bca7326a129313cde0a95597366bdac5c5d24480bd0037d72180271f2e02761a
        57a55fce8b206a6a0f709bdb0764967b43fdcabf9d52eb247b1bee43102cdb92
        a1a8a9f72fd239a8859cfe2c2acf5273fbca20adc9ddfc4a91396c7c8467c5e4
        9b3e3d6b563b2bdc8a46f67c36f9272937387c9da06e5d4ce5b26f0cdceffe35
        fe3d56407fbd4ddd4079dda70a7ba2ce223894ea90f595b6e66f14fba2
        """,
        ciphertext: """
        eca9cc30666c0416218dc81547a218cf19904f822725a21efa1ce4587843524c
        ac24decbad80057aeb2dc03305312544d711a1f2cb096ff0143c3ff2c779fb3f
        b00a65aed7e55d350cb4697a896ba9dc026996d29fe73c99d4d35597c459adc4
        0c7bf8471cbe362a536bb1215fc16eca0a4f163af0d412a6f8689f12ad364cd8
        5a5b17b8bdc72c48517d457400b002e91bd60c41a75d65ca68a73e3cf5aa9bbd
        259800d84dbcd17a25349224a48462632c40a5588190f10f75aa70e44e0fa303
        90d107180a509a3e281f33b711ed3c2c40c8d7e312dcef94937b11c3245161bf
        8ba4a45c850d50494569be5b369084306667763dcc028b9fb79057efe1213465
        3ecabf701d7663bfae1fb255f0873e42f9712802069ef76a473bda385466d9af
        ba7becbfe35263028ba7ad1d7616a22038ec40b7c8356bc2809d2002c634db65
        d8270bc52d85e4dc85ae103601db4baf4479ea2321a083a391f5c5169beb4392
        1f88d2006040e9520b39863b9e3b9a4a31dfb6577838cf777c0cf4149025ed27
        d286204c1a52ebbe1eac2bceb7728687fdac1190c5ea96cbdc89e977f083c3a7
        a7d1e1c97e89b34ef112a39cfe66cc5dcf1d5a11212f1066375fd735eb096299
        a6f8c7c7efd3f0562ba714656acea968e7a489b41e1699bf8d2d5e67b43a0bf3
        37141e5dc6b4b59ea569a4afcc0f46e9d5bb1049070d92420c04b9dfa4b5efcc
        05813fc121122c33b779fd5d8a
        """),
]
