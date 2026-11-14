# 将正式研究分发到研究库

Mac 在研究已正式发布后运行分发工具。工具只读案例的 `published/research/current.json` 及其正式快照，复用现有 `prepare_resources.prepare` 校验和打包，不执行研究、SQL、复算或语义修改，也不改写 App 内置的 `Study`。

从本项目根目录执行，依赖 Python 3.9+ 与 Poppler 的 `pdfinfo`：

```sh
python3 ios/CompanyLens/Tools/publish_study.py \
  --case ../格力2020-2026 \
  --library /path/to/CompanyLensLibrary
```

目标可以是普通本机目录，也可以是同一 Apple 账号的专用 iCloud Drive 目录。先用临时目录核对结果，再指向实际研究库。目标与正式案例目录不能互相包含；工具不会把分发文件写进案例中。

成功向 stdout 输出 JSON，含 `catalog`、`companyId`、`versionId`、库内相对 `packagePath` 和 `created`。重复同版返回 `created: false`；失败以非零状态退出并在 stderr 说明原因。

## 分发目录与发现契约

```text
CompanyLensLibrary/
  catalog.json
  packages/
    <company.id>/
      <versionId>/
        snapshot.json
        resource-manifest.json
        research.json
        research.md
        evidence.md
        reading.json          可选，随正式快照发布
        reports/              完整原 PDF
  .publish.lock               同一 Mac 上分发进程的锁
```

个人阅读记录由阅读设备另存；本工具不创建、删除或改写它们。消费者只从 `catalog.json` 发现成果，忽略隐藏 staging 目录和不在目录清单中的包。

`catalog.json` 的 schemaVersion 为整数 `1`。下面的摘要是说明形状的示例，不能作为已就绪研究使用：

```json
{
  "schemaVersion": 1,
  "companies": [
    {
      "company": {
        "id": "sample-company",
        "name": "Sample Company",
        "code": "SAMPLE",
        "exchange": "TEST"
      },
      "currentVersionId": "sample-r1--1111111111111111111111111111111111111111111111111111111111111111",
      "versions": [
        {
          "versionId": "sample-r1--1111111111111111111111111111111111111111111111111111111111111111",
          "snapshotId": "sample-r1",
          "snapshotManifestSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
          "resourceManifestSHA256": "2222222222222222222222222222222222222222222222222222222222222222",
          "packagePath": "packages/sample-company/sample-r1--1111111111111111111111111111111111111111111111111111111111111111",
          "reportId": "sample-company-study",
          "reportRevision": 1,
          "financialPeriodStart": "2020-01-01",
          "financialPeriodEnd": "2026-09-30",
          "researchAsOf": "2026-11-09"
        }
      ]
    }
  ]
}
```

- `versionId` 固定为 `snapshotId + "--" + snapshotManifestSHA256`，使用完整 64 位小写十六进制摘要。同一快照身份下文件清单字节不同，也成为不同分发版本。
- `snapshotManifestSHA256` 是实际 `snapshot.json` 文件字节的 SHA-256，不能替换成研究正文中的 `publication.manifest_sha256`。
- `resourceManifestSHA256` 是派生 `resource-manifest.json` 文件字节的 SHA-256。该清单由现有打包工具生成，不是引擎正式快照。
- `packagePath` 相对于研究库根目录，固定为 `packages/<company.id>/<versionId>`；不接受绝对路径、反斜杠、空路径段、`.` 或 `..`，库内写入路径及既有包内文件不能是符号链接。
- 公司名称、代码和交易所来自正式研究；没有交易所字段时输出空字符串。期间、截止日期、报告身份与正整数 revision 来自正式报告。
- 同公司首次加入一个版本时，该版本成为 `currentVersionId`。重复已知版本不会把指针退回旧版。新版本不删除旧目录。数组排序只保证稳定输出，不表达版本先后；消费者使用明确指针，不能按目录名或 iCloud 到达顺序猜最新。

目录清单只负责发现。iCloud 可能先同步 `catalog.json`，原件尚未到齐；消费者仍需完整准备并验证后才能打开，不能把条目存在当作就绪。

## 校验、幂等和提交

公开操作是 `publish_study.publish(case, library)`；CLI 使用同一操作。内部只有正式准备与分发提交两步具体实现，不创建第二套研究引擎。

1. 在同一研究库的文件锁内读取现有目录。格式不支持、重复身份、无效 current 指针及不一致版本路径会失败，不能静默清空重建。
2. 在库内独立隐藏目录调用已有打包工具。核对正式快照及指针、每份正式文件摘要、研究与阅读稿绑定、已复核状态，并用 `pdfinfo` 核对来源声明的实际 PDF 页数。研究声明的来源 SHA、正式快照文件 SHA 与实际 PDF 必须一致；只重算外层清单不能绕过来源检查。
3. 由准备好的包构造版本身份和发现元信息。版本已存在时比较完整文件集合与每份文件摘要，包括派生资源清单；任何不同都拒绝，不原地修补。既有同版本目录元信息也必须与准备结果一致。
4. 先写好并同步临时目录清单，再将完整新包同卷 rename 到其唯一最终目录，最后用 `os.replace` 原子替换 `catalog.json`。重复的相同目录清单不重写。
5. 提交前失败保留既有包与目录清单。安装新包后只有在重新读取有效目录、确认它尚未引用新包时才撤掉本次新包；不会删除旧版。原子替换已经成功但回报中断，或目录暂不可读而结果不明时，保留完整包供同版幂等重跑，不能按异常类型推断未提交而删除目录正在引用的包。进程意外终止也可能留下未被目录引用的完整包，重跑会核对并接续，不覆盖它。隐藏 staging 残留不成为可读入口。

文件锁只协调同一 Mac 上运行本工具的进程；它不是 iCloud 分布式锁。此产品由一台 Mac mini 发布，不支持多台 Mac 同时改写同一目录清单。此任务验证本机分发文件及契约，不宣称已验证 iCloud 的真实传输与手机获取。

## 重现验证

```sh
python3 -m unittest discover -s ios/CompanyLens/Tools -p 'test_publish_study.py' -v
python3 -m unittest discover -s ios/CompanyLens/Tools -p 'test_prepare_resources.py' -v
```

测试使用真实临时目录、真实单页 PDF 与公开 `publish`/CLI。系统写入失败只在文件系统调用处注入，不 mock 自己的准备或分发实现。

按已确认测试 seam 逐行为进行 red → green；关键失败先实际复现，再补实现：

| 行为 | 首次失败证据 | 通过后的验证 |
| --- | --- | --- |
| 正式包可发现且原件不变 | `ModuleNotFoundError` | 目录字段、独立包及原始文件逐字节一致 |
| 同版重复 | 最终目录非空导致 rename 失败 | `created: false`，包与目录字节、目录修改时间不变 |
| 既有版本被修改 | 未抛出预期错误 | 改 PDF、派生清单或添加额外文件均拒绝 |
| 新旧版本保留 | 目录中仅有一个版本 | 追加新版、保留旧包，重复旧版不回退 current |
| CLI | stdout 为空，JSON 解码失败 | 指定正式案例与目标库得到可解析结果 |
| 目录提交失败 | 失败后留下新版本文件 | 保留原库字节并撤销本次新包 |
| 案例目录内写分发结果 | 未拒绝重叠路径 | 创建任何目标文件前拒绝 |
| 符号链接重定向 | 库根、packages、catalog 三例均未拒绝 | 拒绝且库外文件不变 |
| 并发分发 | 12 家公司丢失其中 8 个目录条目 | 同一库文件锁下全部保留 |
| 损坏目录清单 | 未拒绝未知 schema、重复公司或错误路径 | 不覆写目录、不安装新包 |
| 既有目录缺少必需元信息 | 未拒绝缺少公司名称或截止日期 | 与新分发使用同一元信息校验，不保留不能加载的条目 |
| 无效发现元信息 | 未拒绝嵌套公司路径、空名称、无效 revision/日期 | 明确失败且已有目录不变 |
| 未知正式发布格式 | 未拒绝未知 snapshot/pointer schema | 校验正式 envelope 与精确阶段身份 |
| 临时目录清单写失败 | 已经安装新包 | 在安装前完成目录 staging，失败不改变已有库 |
| 同版本发现元信息不一致 | 未抛出错误 | 派生清单摘要不一致时拒绝重复发布 |
| 目录已经提交后回报中断 | `KeyboardInterrupt`、普通 `OSError` 两例均令 current 指向不存在的包 | 重新观察目录；保留已引用包，同版重跑不重写且完整可读 |

来源 SHA/页数不匹配的检查由现有准备实现已经提供，新增公开操作回归测试直接通过；没有为制造 red 修改既有行为。额外回归验证了四个 CLI 进程同时发布同版只产生一个版本、先复制目录清单后补齐包的 fixture，以及提交结果不明且目录暂不可读时保留完整包、稍后重跑恢复的路径。

2026-11-14 完成全部 27 项工具测试（19 项分发、8 项既有准备）。在临时目录对正式格力案例完成发布与重复：15 份正式快照文件、11 份原 PDF 摘要一致，`published` 源目录字节不变，重复时目录字节不变。另在正式包的临时副本中改错来源摘要，并重新匹配研究/阅读绑定和外层清单；分发仍报来源哈希不匹配，已发布研究库字节保持不变。正式 `snapshot.json` 摘要为 `8b903db1a5461c5c1b3e835491d3d3eab00c001dcf450314f3c5514e1e34589f`，无额外 App logo 的派生资源清单摘要为 `489b83c92ee11a4636118db98733dccebb0c988135e9c67a3ad5ae86e65a7ef1`。
