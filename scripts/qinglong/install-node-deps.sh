#!/bin/bash
# ---------------------------------------------------------------------------
# 把青龙容器里三个"面板说已安装、实际 require 就炸"的 Node 依赖换成可用版
#
#   1) ts-md5     2.0.1 -> 1.3.1
#      2.0.1 是发布事故：exports.require 指向 dist/index.cjs.js，可包又声明了
#      "type":"module"，而 .js 结尾在 "type":"module" 下一律按 ESM 解析，
#      于是 CJS 代码报 "exports is not defined in ES module scope"。
#      1.3.1 是纯 CJS（main = dist/cjs/index.js），不再有这个问题。
#
#   2) jsdom      30.1.1 -> 26.1.0
#      30.x 要求 Node >= 22，容器是 20.20.2；26.1.0 的 engines 是 >=18。
#
#   3) jieba      1.0.0(坏包) -> 壳转发到 @node-rs/jieba@1.10.4
#      npm 的 jieba@1.0.0 发布缺文件（main 指向的 index.js 不在 tarball 里）。
#      @node-rs/jieba 有 linux-arm64-gnu 预编译，**手机上不需要编译**。
#      1.x 是顶层函数 API（cut/cutAll/cutForSearch/tag/extract），与 nodejieba
#      一致；v2 把 API 改成了类（只有 Jieba/TfIdf/CutTask），所以刻意钉 1.10.4。
#      再放一个叫 jieba 的壳，让老写法 require('jieba') 照旧能用。
#
# 用法（在设备上以 root 执行，幂等，可重复跑）：
#     bash install-node-deps.sh
#
# ⚠️ 两个坑，都踩过：
#   a) 壳放在 /ql/data/scripts/node_modules/ 下，**不属于** pnpm 管辖的全局树，
#      所以 `pnpm add -g 别的包` 不会把它当 extraneous 清掉。
#      （试过把壳放进全局树、以及用 `pnpm add -g file:...` —— 前者有被清风险，
#        后者 pnpm 8 直接判 "Already up to date" 不肯落地。）
#   b) 软链目标必须写**容器内的路径**（/ql/data/...）。在宿主机上按
#      /root/qinglong/data/... 建链，进容器就是断链。
#
# ⚠️ 装完别在青龙面板里给这三个点"重装" —— 面板按名字拉最新版，
#    ts-md5/jsdom 会退回坏版本，jieba 会装回那个坏包。
#
# 参考副本：scripts/qinglong/jieba-shim/{package.json,index.js}（保持同步）
# ---------------------------------------------------------------------------
set -u

CONTAINER=qinglong
HOST_DATA=/root/qinglong/data                 # 容器内 = /ql/data
G=/ql/data/dep_cache/node/global/5            # pnpm 全局目录（容器内视角）
NS=/ql/data/scripts/node_modules              # 壳放这（容器内视角）
SHIM_DIR="$HOST_DATA/scripts/node_modules/jieba"

say() { echo "== $*"; }

say "1/4 pnpm 安装（arm64 预编译，不在手机上编译任何东西）"
docker exec "$CONTAINER" sh -lc "
  export PATH=/ql/data/dep_cache/node:\$PATH
  pnpm add -g ts-md5@1.3.1 jsdom@26.1.0 @node-rs/jieba@1.10.4 2>&1 | tail -8
" || { echo "!! pnpm 安装失败，停"; exit 1; }

say "2/4 放 jieba 兼容壳"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/package.json" <<'JSON'
{
  "name": "jieba",
  "version": "1.10.4-z17s.1",
  "private": true,
  "description": "z17s shim: npm 上的 jieba@1.0.0 是坏包(main 指向不存在的 index.js)，这里转发到可用的 @node-rs/jieba，保持 require(jieba) 可用",
  "main": "index.js",
  "dependencies": {
    "@node-rs/jieba": "^1.10.4"
  }
}
JSON
cat > "$SHIM_DIR/index.js" <<'JS'
module.exports = require('@node-rs/jieba');
JS

# 软链在容器内建，目标写容器路径
docker exec "$CONTAINER" sh -lc "
  set -e
  mkdir -p $NS/@node-rs
  ln -sfn $G/node_modules/@node-rs/jieba $NS/@node-rs/jieba
  echo '  jieba 壳:'; ls -la $NS/jieba/
  echo '  @node-rs:'; ls -la $NS/@node-rs/
  [ -e $NS/@node-rs/jieba/package.json ] && echo '  软链有效' || { echo '  软链无效!'; exit 1; }
" || { echo "!! 建链失败，停"; exit 1; }

say "3/4 真调用验证"
docker exec "$CONTAINER" sh -lc "cd /ql/data/scripts && node -e '
const t=[];
const go=(n,f)=>{try{t.push([\"PASS\",n,f()])}catch(e){t.push([\"FAIL\",n,(e.message||e)+\"\"])}};
go(\"ts-md5\",()=>require(\"ts-md5\").Md5.hashStr(\"hello\"));
go(\"jsdom\",()=>new (require(\"jsdom\").JSDOM)(\"<p id=x>ok</p>\").window.document.querySelector(\"#x\").textContent);
go(\"jieba\",()=>JSON.stringify(require(\"jieba\").cut(\"我们中出了一个叛徒\",true)));
go(\"jieba 解析到\",()=>require.resolve(\"jieba\"));
t.forEach(([s,n,d])=>console.log(\"[\"+s+\"] \"+n+\"  \"+d));
'"

say "4/4 完事"
echo "  完整自检："
echo "    docker exec $CONTAINER env NODE_PATH=$G/node_modules node /ql/data/scripts/z17s_depcheck.js"
echo "  或在青龙面板点「Z17S 依赖自检」任务的运行按钮（日志在 /ql/data/log/z17s_depcheck/）。"
