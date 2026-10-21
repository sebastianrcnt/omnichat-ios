import Foundation

// Throwaway keys made with ssh-keygen for the parsing tests (they open nothing). `public` is ssh-keygen's .pub line
// without its comment, `fingerprint` what ssh-keygen -l prints. The encrypted ones use the passphrase "fixture".
enum SSHKeyFixtures {
    struct Key { let file: String; let privateKey: String; let publicKey: String; let fingerprint: String }

    static let all: [Key] = [
        Key(file: "ed", privateKey: """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACC/0lckEn1NsG3tq1dQkSq9Zo8br7dY9+dF/osW1GFCoQAAAJDP4ZHLz+GR
ywAAAAtzc2gtZWQyNTUxOQAAACC/0lckEn1NsG3tq1dQkSq9Zo8br7dY9+dF/osW1GFCoQ
AAAEDamtBwW5vEjgouPZiENSpFXn0EHY/NxQZbj68/TNT8tb/SVyQSfU2wbe2rV1CRKr1m
jxuvt1j350X+ixbUYUKhAAAACmZpeHR1cmUtZWQBAgM=
-----END OPENSSH PRIVATE KEY-----
""",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL/SVyQSfU2wbe2rV1CRKr1mjxuvt1j350X+ixbUYUKh",
            fingerprint: "SHA256:q2H0yFG4UYo4IjEE6hPGZknhkcmOB9ellK6xNZPWs4E"),
        Key(file: "ecpem", privateKey: """
-----BEGIN EC PRIVATE KEY-----
MIIBaAIBAQQg/c1ZF+a0UKF/pLAxE0psCHIOIde8q4BZ4VWQFlwWKX2ggfowgfcC
AQEwLAYHKoZIzj0BAQIhAP////8AAAABAAAAAAAAAAAAAAAA////////////////
MFsEIP////8AAAABAAAAAAAAAAAAAAAA///////////////8BCBaxjXYqjqT57Pr
vVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMVAMSdNgiG5wSTamZ44ROdJreBn36QBEEE
axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54W
K84zV2sxXs7LtkBoN79R9QIhAP////8AAAAA//////////+85vqtpxeehPO5ysL8
YyVRAgEBoUQDQgAE/CIdWCRq0k6zYQJZv8Mqn8NjvzejDws2HTIj/pXiL/Tpy0Fb
BR/JeB7sAWqQ8m9qL3YFUo1R+MfB4JUxlJu88Q==
-----END EC PRIVATE KEY-----
""",
            publicKey: "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBPwiHVgkatJOs2ECWb/DKp/DY783ow8LNh0yI/6V4i/06ctBWwUfyXge7AFqkPJvai92BVKNUfjHweCVMZSbvPE=",
            fingerprint: "SHA256:zOeWO4I4sxsCwHGEPEtVhnhB9j8GCYRJ9QgPzGy0Zec"),
        Key(file: "rsapem", privateKey: """
-----BEGIN RSA PRIVATE KEY-----
MIICXAIBAAKBgQCy/W49v3KRI7feHUPEsD4JyPiIHjZt46UpjczoIJrGLTc4Ga2z
p67sOAYcwP04riah4SDLCZo4ZwJwgphB7WHsJaoHsh+DlCn1LVF1J2Tr4MC5Xuj8
uGDp4P0R0JPmJqrnaQgR8H4P5K5TUI7rOKEKl26Ndy0a15h5XFWvSa6/EQIDAQAB
AoGAKx/gZcQwqEOA02UdpNAJwnXHW5Rb7NICQybFDdB9Oe4+9adKMJTgEk3VOyxM
VlGvQSVqr0CbBafb8Jumb4vwIXwP6fMRKDR92STVZmmCTQtDRSQAykXQKZ1kEFiN
lr65n9dA7Qa1jCwhdxriKsMLzOg2nWYn8Ny0CG+OX3ckjSECQQDhcpG8Y0WRfin2
kRTqoUXaRtDkBwpO0LBeTptp3z9WNMrz9387YbbucF8YRB3T4qEWPi09KvpZwssF
Hev1pwltAkEAyz8c7454FyF4389FgQIwQzyVtZL0J0+TymEyVHN80W2bQm+boWL9
Eq9kHWxWDDZ8HeCM5YSXSdeLEX1dOllJtQJAdLSgaMtjCgwroO49y7AsvvAF1uUm
GuLBSjCbF1VwLioqHd0zSgQtdIVLVP5+Cl+5UBBjztRewPSrsDxrF8GeiQJAf7M6
4gU4zQe5451ehS0z17sEMV6QyvZD3H9vWQJq5Uchqv9m4GLKsWfD1nzQH8JH/5mr
zTWevMWR2j5TSir5lQJBAJapeBVmOuXzVmhAmstBLp7H7ji+Sb7GdNlw+nRpVFdl
LtgsDazQdgdiX+94orEP0QFIOoowxfPlyNsztQKoOn0=
-----END RSA PRIVATE KEY-----
""",
            publicKey: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQCy/W49v3KRI7feHUPEsD4JyPiIHjZt46UpjczoIJrGLTc4Ga2zp67sOAYcwP04riah4SDLCZo4ZwJwgphB7WHsJaoHsh+DlCn1LVF1J2Tr4MC5Xuj8uGDp4P0R0JPmJqrnaQgR8H4P5K5TUI7rOKEKl26Ndy0a15h5XFWvSa6/EQ==",
            fingerprint: "SHA256:wJ6EXK8wgOpHpKrp3zae77sTh/a7D11jPmQRotxhHAY"),
        Key(file: "rsap8", privateKey: """
-----BEGIN PRIVATE KEY-----
MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBAL/0atC5SAJLf33U
bwg5TE9UWGE3RLH+cppLHfw/mtSozMQh9pts6bjFQEb0QXCsyQBgoY9XeOtnAx8V
DwQNwSOHAx51RIgeq1C4iGrq/X8tIHPmzMlmvP94ebqFTM7My0ASOVj8USyb7eEg
FCphcvMR0Er72tjCGMpmh1HEFwQDAgMBAAECgYEAu2Q13tvyQ2NG7CU127ZsG8nA
me9lncpEQQJyHG5PjanYdOSfJe52YM4XyOzs8b2MYFT1g8UmI9Elx/M7/H4c/Arj
26VU9rRFbv85VPtpV/Wf5MQv4rLP0v645k3omV45Mpg3eoTDC+A43QT0Vg7Mtst/
M7EfXQQFI/RaVT54l5kCQQDvGRkAXxugTxu9OuZHOjs9Ew7NE0Se0ERIaY2A8cBw
sLEmYeO5A3crkudG7xxwtBWtixKivIgkjgjhPjJgmQpfAkEAzYYtrE3OUBB/Pk62
tITZ9osEwa1b8NYIU63mRUPvdlyyW/ZOJB+AxsrzpZxD+T3DmjVGLORFdEaeIIcF
QcDw3QJAZOaZh2+bj/5yfVwC3CI156NIRsEP31mSx2BMCBN9m9DlIYaD/Ir62pen
JGc6AFHvKAqdtbGMXqjWFIAT8HIFTwJAAPGl0g3Fbc61luarpiaaDazTx8PxESka
fq/kx9qpBeUlGJEICNhwMfmKpu8RzNpAxLuL5/bgbslIPqQAHS4yrQJBAN6StcDW
nwYL80BpQHniXsbMaSYwIuEPZzaEDTo3+XlrUVEvf7bm6yYgBvp4/MTsQ8cR7tyB
9Q5tLQUzkGwIORc=
-----END PRIVATE KEY-----
""",
            publicKey: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQC/9GrQuUgCS3991G8IOUxPVFhhN0Sx/nKaSx38P5rUqMzEIfabbOm4xUBG9EFwrMkAYKGPV3jrZwMfFQ8EDcEjhwMedUSIHqtQuIhq6v1/LSBz5szJZrz/eHm6hUzOzMtAEjlY/FEsm+3hIBQqYXLzEdBK+9rYwhjKZodRxBcEAw==",
            fingerprint: "SHA256:P41MAIjDhppv8Ak6q/+l2ADIeCdA0orL2jbosfJLZ5k"),
        Key(file: "ecp8", privateKey: """
-----BEGIN PRIVATE KEY-----
MIICDAIBADCCAWQGByqGSM49AgEwggFXAgEBMDwGByqGSM49AQECMQD/////////
/////////////////////////////////v////8AAAAAAAAAAP////8wewQw////
//////////////////////////////////////7/////AAAAAAAAAAD////8BDCz
MS+n4j7n5JiOBWvj+C0ZGB2cbv6BQRIDFAiPUBOHWsZWOY2KLtGdKoXI7dPsKu8D
FQCjNZJqoxmieh0AiWpnc6SCes2scwRhBKqHyiK+iwU3jrHHHvMgrXRuHTtii6eb
mFn3QeCCVCo4VQLyXb9VKWw6VF44cnYKtzYX3kqWJixvXZ6Yv5KS3Cn49B29KJoU
fOnaMRO18LjACmCxzh1+gZ16Qx18kOoOXwIxAP//////////////////////////
/////8djTYH0Ny3fWBoNskiwp3rs7BlqzMUpcwIBAQSBnjCBmwIBAQQwrKg53WdH
MyfA/jP1elVsvC0wd0sVux8OqqQbFfr0k8J/3Nt943Q2uDCHNfDDCQFFoWQDYgAE
k6XN3GVfq9oWJ01CrmRWc3gqWM97c/o0FI/MLwSTkD+zsLmxxn6z4kYBH5D6482V
CD1Or3ED+5HAEzc/lgO0zYVvjQ0vmnN03/sdWan42oT8LYQeF6j0BDv3VpR146wf
-----END PRIVATE KEY-----
""",
            publicKey: "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBJOlzdxlX6vaFidNQq5kVnN4KljPe3P6NBSPzC8Ek5A/s7C5scZ+s+JGAR+Q+uPNlQg9Tq9xA/uRwBM3P5YDtM2Fb40NL5pzdN/7HVmp+NqE/C2EHheo9AQ791aUdeOsHw==",
            fingerprint: "SHA256:OQlR7nnSZa16F/dEolkW7oYaKIz/W3H6koLsvLxWuTM"),
        Key(file: "edenc", privateKey: """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABD/lHB+Qc
/s7pSqqkKmOxInAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIHIxfqd4aSx52SNm
CRI/ceJGAeg+MMPWdMF2UOHudvEwAAAAkPJtc+KGmgt8jLO0zPToZ7NucVLYz/W7ald/fc
QYvThNVJb9bs6/WwMys+i6hOJCIxeF7Dx8DT371hVvGxQKBbcO5SQ+Uyb64xknG1uPUZds
xpVeRxOzkTlU0l36SHgC6+XsGHX5jTdnI4qs59KXw3JoCYaST+gigzTLiyXBdWBhMYItKp
+m1RMeszgHoJh0BA==
-----END OPENSSH PRIVATE KEY-----
""",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHIxfqd4aSx52SNmCRI/ceJGAeg+MMPWdMF2UOHudvEw",
            fingerprint: "SHA256:csPhKBIoT4mUrSFFrqfa+gQRo3K8Lb0H8gXuv2DJz44"),
        Key(file: "rsapemenc", privateKey: """
-----BEGIN RSA PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-128-CBC,FEC8628F1DDCC847B1583A25350608C4

aCbEjAJnTtGNmWNN/0eLzurxs+NpSF/qmWnZxXNYg+xB8b0z9LCRo1HSdt6Lwnl8
e1U9oMshCd/rNCju4leZvur+VaWJ2G53XqsbWgxvSTzTF3A2+qonXz48eTWzMq4d
PiDwp+4RZIyTxsRQZmfKfJcry13w6D+HMaoANolXrisHYlAplA/wRl8hd0ShiSTJ
FKuyWZpTV/g5EgeVp4ubTIYhyafl3mMNDG7R18WtWi6vIr7njVum3NELvleNSzmZ
x3fKOWVGmVpcQ6U/Q2/gCtybS/xw2YuWXppqMCRhpbSPnof2M8CQIuum9DT9+lxf
QXETSP4nUbueDJ/w2cQKOgQPbnrrtc3Q7tuZ3EESrA67FIfG6aQtcu6p8TteHdOy
95pwWdEJKe0IYiQg0fylBSEMMcqEiMvmIJNvnxj8eKqIo+n6x1ZRhtqjyBTlB+qj
pRNo2MBlJ99mQQB0AkGRRGYdb3oaU2qtXyBQbcRDZIZcawfxPlxsXOPZFwmCgjCk
s76kNA8WriFe5DaUiZocPaZpN44a4f4+wEBdqjn2Ww1/YdWar3qxj3JK+pVRNBF6
8Flo/xaizIjmOp4l7OLdeeWCLm6JViTV1Rt4wOYj5+mabbQxN+Rkm1nO0yx216ib
1f6YQJZ/5/6O1H2/IKgsbb4vW9YYjwQakIgvnPhbKo3Nb8b3E68I6GrQ6pN/G7vF
tI8sHp56av+3mJc7FGbPuruEhkG7nM0wVebbQjekFHGMVsSMqlS4NwNbZ/MaMn6H
608aOdR6Yt+bfmhZJ0u5rx88PQ1ask/6lvbe0jov3TJjaTLSmFZcfjHMhnZfuw3M
-----END RSA PRIVATE KEY-----
""",
            publicKey: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQCVZgXFUbagUfkJiWC83up4Yv2g+iwNIilEOxySirGhgAHExBD6JfEoKklOmrbfAfUazlYbpBHElwPVmZ6LF68fCrpmrr6vS0FDckKvRsC0/0xHDUMSJnFwj6hq4Fv7s1aGcVAssTjtDPo1bfCNYBwa8r2c40toMMzC1kig5nQZkQ==",
            fingerprint: "SHA256:dofG2KlEMlUnQqd4FX3G86SuyBczc2ArYo7M9fvZrLE"),
    ]

    static func key(_ file: String) -> Key { all.first { $0.file == file }! }
}
