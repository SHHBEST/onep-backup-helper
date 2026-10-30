-- ============================================================
-- 1P备份助手
-- age 加密 / 解密的图形界面，全中文。
-- 后端逻辑在 Contents/Resources/helper.sh
-- ============================================================

property appTitle : "1P备份助手"

-- ---------- 路径与命令 ----------

on resDir()
	set p to POSIX path of (path to me)
	if p ends with "/" then set p to text 1 thru -2 of p
	return p & "/Contents/Resources/"
end resDir

on helperCmd()
	return "/bin/bash " & quoted form of (my resDir() & "helper.sh")
end helperCmd

on keyDir()
	return (POSIX path of (path to home folder)) & "Library/Application Support/1P备份/"
end keyDir

-- ---------- 工具函数 ----------

on parseValue(txt, key)
	repeat with ln in paragraphs of txt
		set s to ln as text
		if s starts with (key & "=") then return text ((length of key) + 2) thru -1 of s
	end repeat
	return ""
end parseValue

on revealPath(p)
	try
		tell application "Finder"
			activate
			reveal (POSIX file p as alias)
		end tell
	end try
end revealPath

on friendly(errMsg, errNum)
	set m to errMsg as text
	if errNum is 3 then return "还没有生成密钥。请先点「生成密钥」。"
	if errNum is 4 then return "目标文件或校验文件已经存在，程序没有覆盖。" & return & return & "请保留已有文件，检查后为输入文件改名，或换到空文件夹再操作。" & return & m
	if errNum is 5 then return "加密失败。" & return & m
	if errNum is 6 then return "这不是有效的 age 加密文件，或者文件已经损坏。"
	if errNum is 7 then return "本机没有私钥，无法解密。" & return & return & "请把私钥文件复制到：" & return & my keyDir() & "private.key"
	if errNum is 8 then return "解密失败：私钥和这个备份不匹配，或者文件已经损坏。"
	if errNum is 9 then return "已经存在私钥，程序拒绝覆盖。" & return & return & "若原私钥没有其他副本，覆盖会导致旧备份无法恢复。"
	if errNum is 11 then return "这个文件是空的，没有可加密的内容。"
	if errNum is 12 then return "公钥文件内容异常，请检查。" & return & m
	if errNum is 16 then return "旁边没有找到 .sha256 校验文件，无法核对。"
	if errNum is 17 then return "校验文件内容异常。"
	if errNum is 18 then return "校验失败：这个备份和当初记录的不一致，可能已经损坏或被改动。"
	if errNum is 19 then return "这个文件已经是加密过的，不需要再加密。"
	if errNum is 20 then return "公钥还在，但私钥缺失。程序不会自动更换密钥。" & return & return & "请找回原来的 private.key；新生成的私钥不能解开旧备份。"
	if errNum is 21 then return "文件或校验记录未能完整保存，请勿删除原文件。" & return & return & "检查剩余空间和目录权限。若已产生 .age，请保留它；改名或换空文件夹后重试。" & return & m
	if errNum is 22 or errNum is 23 or errNum is 24 then return m
	if errNum is 90 or errNum is 91 then return "程序内部文件缺失，请重新下载完整的「1P备份助手」。"
	return "操作失败（代码 " & errNum & "）：" & return & m
end friendly

-- ---------- 主流程 ----------

on run
	my mainMenu()
end run

on mainMenu()
	set H to my helperCmd()
	set hasKey to false
	try
		do shell script H & " public"
		set hasKey to true
	on error errMsg number errNum
		if errNum is not 3 then
			display alert appTitle message my friendly(errMsg, errNum) as warning
			return
		end if
	end try
	
	if hasKey then
		set pubStr to ""
		try
			set pubStr to do shell script H & " public"
		end try
		set msg to "加密你的 1Password 备份，或者把备份解密回来。" & return & return & ¬
			"也可以直接把文件拖到本程序图标上：" & return & "· .age 文件 → 解密" & return & "· 其他文件 → 加密" & return & return & ¬
			"当前公钥：" & return & pubStr
		set btns to {"更多…", "解密恢复", "加密备份"}
		set dflt to "加密备份"
	else
		set msg to "还没有生成密钥。" & return & return & ¬
			"密钥只需生成一次，之后每次备份都用它加密。" & return & ¬
			"生成之后，请立刻把私钥备份到 U 盘和移动硬盘。"
		set btns to {"更多…", "生成密钥"}
		set dflt to "生成密钥"
	end if
	
	try
		set r to display dialog msg buttons btns default button dflt with title appTitle with icon note
	on error number -128
		return
	end try
	
	set c to button returned of r
	if c is "加密备份" then
		my doEncrypt(missing value)
	else if c is "解密恢复" then
		my doDecrypt(missing value)
	else if c is "生成密钥" then
		my doKeygen()
	else
		my doMore()
	end if
end mainMenu

-- 拖拽文件到图标上时走这里
on open theFiles
	if (count of theFiles) is 0 then return
	set f to item 1 of theFiles
	if (count of theFiles) > 1 then
		display dialog "一次处理一个文件。" buttons {"好"} default button 1 with title appTitle
	end if
	set p to POSIX path of f
	if p ends with ".age" then
		my doDecrypt(f)
	else
		my doEncrypt(f)
	end if
end open

on reopen
	my mainMenu()
end reopen

-- ---------- 加密 ----------

on doEncrypt(givenFile)
	set f to givenFile
	if f is missing value then
		try
			set f to choose file with prompt "选择要加密的文件（例如 1Password 导出的 .1pux）"
		on error number -128
			return
		end try
	end if
	
	set H to my helperCmd()
	try
		with timeout of 600 seconds
			set out to do shell script (H & " encrypt " & quoted form of (POSIX path of f))
		end timeout
	on error errMsg number errNum
		display alert appTitle message my friendly(errMsg, errNum) as warning
		return
	end try
	
	set agePath to my parseValue(out, "OK_PATH")
	set sha to my parseValue(out, "OK_SHA256")
	
	set r to display dialog "加密完成。" & return & return & ¬
		"文件：" & agePath & return & return & ¬
		"SHA256：" & sha & return & return & ¬
		¬
			"原文件仍是明文。请把 .age 和 .sha256 一起备份；校验并确认可解密后再删除明文。" buttons {"好", "在访达中显示"} default button "在访达中显示" with title appTitle with icon note
	
	if button returned of r is "在访达中显示" then my revealPath(agePath)
end doEncrypt

-- ---------- 解密 ----------

on doDecrypt(givenFile)
	set f to givenFile
	if f is missing value then
		try
			set f to choose file with prompt "选择要解密的 .age 备份文件"
		on error number -128
			return
		end try
	end if
	
	set H to my helperCmd()
	try
		with timeout of 600 seconds
			set out to do shell script (H & " decrypt " & quoted form of (POSIX path of f))
		end timeout
	on error errMsg number errNum
		display alert appTitle message my friendly(errMsg, errNum) as warning
		return
	end try
	
	set outPath to my parseValue(out, "OK_PATH")
	
	set r to display dialog "解密完成。" & return & return & ¬
		"文件：" & outPath & return & return & ¬
		¬
			"这是明文的密码库，导入 1Password 之后请立刻删除。" buttons {"好", "在访达中显示"} default button "在访达中显示" with title appTitle with icon caution
	
	if button returned of r is "在访达中显示" then my revealPath(outPath)
end doDecrypt

-- ---------- 校验备份 ----------

on doVerify()
	set H to my helperCmd()
	try
		set f to choose file with prompt "选择要校验的 .age 备份文件（需和 .sha256 放在一起）"
	on error number -128
		return
	end try
	
	try
		with timeout of 600 seconds
			set out to do shell script (H & " verify " & quoted form of (POSIX path of f))
		end timeout
	on error errMsg number errNum
		display alert appTitle message my friendly(errMsg, errNum) as warning
		return
	end try
	
	display dialog "校验通过。" & return & return & "文件与这份 .sha256 记录一致。" & return & return & "这不代表私钥可用，也不能防止文件与校验记录同时被替换；请另做一次解密恢复演练。" buttons {"好"} default button 1 with title appTitle with icon note
end doVerify

-- ---------- 生成密钥 ----------

on doKeygen()
	set H to my helperCmd()
	try
		set out to do shell script H & " keygen"
	on error errMsg number errNum
		display alert appTitle message my friendly(errMsg, errNum) as warning
		return
	end try
	
	set pubStr to my parseValue(out, "OK_PUB")
	set resultTitle to "密钥已生成。"
	if (my parseValue(out, "NOTE")) is not "" then set resultTitle to "公钥已从原私钥恢复，私钥未更换。"
	
	set r to display dialog resultTitle & return & return & ¬
		"公钥：" & return & pubStr & return & return & ¬
		"现在最重要的一步：备份私钥。" & return & ¬
		"位置：" & my keyDir() & "private.key" & return & return & ¬
		"把它复制到 U 盘和移动硬盘各一份。" & return & ¬
		¬
			"私钥丢了，所有加密备份都打不开。" buttons {"复制公钥", "打开密钥文件夹"} default button "打开密钥文件夹" with title appTitle with icon caution
	
	if button returned of r is "复制公钥" then
		set the clipboard to pubStr
		display dialog "公钥已复制到剪贴板。可以贴到任何地方，它不是秘密。" buttons {"好"} default button 1 with title appTitle
	else
		my revealPath(my keyDir())
	end if
end doKeygen

-- ---------- 更多 ----------

on doMore()
	set H to my helperCmd()
	set opts to {"查看公钥", "校验备份", "打开密钥文件夹", "自检", "使用说明"}
	try
		set sel to choose from list opts with prompt "选择操作" default items {"查看公钥"} with title appTitle
	on error number -128
		return
	end try
	if sel is false then return
	set s to item 1 of sel
	
	if s is "查看公钥" then
		try
			set p to do shell script H & " public"
			set the clipboard to p
			display dialog "公钥已复制到剪贴板：" & return & return & p buttons {"好"} default button 1 with title appTitle
		on error errMsg number errNum
			display alert appTitle message my friendly(errMsg, errNum) as warning
		end try
		
	else if s is "打开密钥文件夹" then
		my revealPath(my keyDir())
		
	else if s is "校验备份" then
		my doVerify()
		
	else if s is "自检" then
		try
			with timeout of 600 seconds
				do shell script (H & " selftest")
			end timeout
			display dialog "自检通过。" & return & return & "公钥和私钥配对正常，加密、解密整条链路可用。" buttons {"好"} default button 1 with title appTitle
		on error errMsg number errNum
			display alert "自检未通过" message my friendly(errMsg, errNum) as warning
		end try
		
	else if s is "使用说明" then
		display dialog "怎么用" & return & return & ¬
			"1. 每月一次：在 1Password 里 文件 > 导出 > 选 .1pux，存到桌面或某个文件夹。" & return & return & ¬
			"2. 把那个 .1pux 拖到本程序图标上，得到同名 .age 文件。" & return & return & ¬
			"3. 把 .age 和 .sha256 一起传到 NAS，校验并确认可解密后删除 .1pux 明文。" & return & return & ¬
			"4. 需要恢复时：把 .age 放进空文件夹，再拖到本程序上；本机有对应私钥即可解密，之后导入 1Password。" & return & return & ¬
			"密钥在哪里" & return & my keyDir() & return & return & ¬
			¬
				"private.key 是私钥，必须另外备份。public.key 是公钥，公开无妨。" buttons {"好"} default button 1 with title appTitle
	end if
end doMore

