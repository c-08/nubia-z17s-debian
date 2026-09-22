/* z17s shim —— 见同目录 package.json 的 description。
 *
 * npm 的 jieba@1.0.0 是坏包：package.json 的 main 指向 index.js，
 * 但发布的 tarball 里没有这个文件，require 必然抛
 *   Cannot find module ".../node_modules/jieba/index.js"
 *
 * 这里转发到 @node-rs/jieba（linux-arm64-gnu 预编译，本机无需编译）。
 * 它的 1.x API 与 nodejieba 一致，也是顶层函数：
 *   cut / cutAll / cutForSearch / tag / extract / load ...
 *
 * 注意：v2 把 API 改成了类（exports 只有 Jieba / TfIdf / CutTask），
 * 所以这里刻意钉在 1.10.4。
 */
module.exports = require('@node-rs/jieba');
