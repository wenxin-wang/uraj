(list (channel
       (name 'guix)
       (url "https://mirror.nju.edu.cn/git/guix.git")
       (branch "master")
       (commit "90d978cb9a60a3ea5bf676c9637ae2f718304a31")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
       (name 'nonguix)
       (url "https://gitlab.com/nonguix/nonguix")
       (branch "master")
       (commit "f9171dd0d0a58d63c0811d61e51493a3fa4ae4f3")
       (introduction
        (make-channel-introduction
         "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
         (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
      (channel
       (name 'rosenthal)
       (url "https://codeberg.org/hako/rosenthal.git")
       (branch "trunk")
       (commit "8bebafaacdd9ea7b0bc7159857206b1959a0df2d")
       (introduction
        (make-channel-introduction
         "7677db76330121a901604dfbad19077893865f35"
         (openpgp-fingerprint
          "13E7 6CD6 E649 C28C 3385  4DF5 5E5A A665 6149 17F7"))))
      (channel
       (name 'pantherx)
       (url "https://codeberg.org/gofranz/panther.git")
       (branch "master")
       (commit "cf52b811d82e8d3e6bd2581f3dda39b0c6b153bd")
       (introduction
        (make-channel-introduction
         "54b4056ac571611892c743b65f4c47dc298c49da"
         (openpgp-fingerprint
          "A36A D41E ECC7 A871 1003  5D24 524F EB1A 9D33 C9CB"))))
      (channel
       (name 'sops-guix)
       (url "https://github.com/fishinthecalculator/sops-guix.git")
       (branch "main")
       (commit "c53e27e533836ea8595626ba6796dee5362f8c4a")
       (introduction
        (make-channel-introduction
         "0bbaf1fdd25266c7df790f65640aaa01e6d2dbc9"
         (openpgp-fingerprint
          "8D10 60B9 6BB8 292E 829B  7249 AED4 1CC1 93B7 01E2")))))
