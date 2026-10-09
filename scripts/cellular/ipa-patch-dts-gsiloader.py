#!/usr/bin/env python3
# Add qcom,gsi-loader = "modem" to the &ipa node of msm8998-nubia-nx595j.dts
import shutil

p = "/root/z17s-kbuild/linux-6.12.95/arch/arm64/boot/dts/qcom/msm8998-nubia-nx595j.dts"
shutil.copy2(p, p + ".orig-gsiloader")

t = open(p).read()
old = '&ipa {\n\tstatus = "okay";\n\tmemory-region = <&ipa_fw_mem>;\n\tfirmware-name = "qcom/msm8998/nubia/ipa_fws.mbn";\n};'
new = '&ipa {\n\tstatus = "okay";\n\tmemory-region = <&ipa_fw_mem>;\n\tfirmware-name = "qcom/msm8998/nubia/ipa_fws.mbn";\n\tqcom,gsi-loader = "modem";\n};'
assert t.count(old) == 1, "anchor count=%d" % t.count(old)

open(p, "w").write(t.replace(old, new, 1))
print("DTS patched: added qcom,gsi-loader = modem")
