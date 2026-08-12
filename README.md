# time-tracker-deploy

工数管理システム **[time-tracker](https://github.com/hir-of/time-tracker)** のデプロイ構成（Helm チャート・SealedSecret・ArgoCD 定義）。

| | |
|---|---|
| デプロイ先 | k3s クラスタ **`baas-test`**（`https://7ffc7a95.kubo-test.hexabase.io:6443`） |
| namespace | `time-tracker` |
| 公開 URL | https://test-time-tracker.kubo.hexabase.io |
| レジストリ | `harbor.hexabase.io` / プロジェクト `c-furukawa-test` |

> **`kubectl` は常に `--context baas-test` を明示すること。**
> グローバル context を切り替えると、同じ kubeconfig を共有する他のシェル・プロセスに
> 影響し、意図しないクラスタへの操作を静かに引き起こす。

## なぜアプリと別リポジトリなのか

**変更の頻度と理由が違うから。**

```
hir-of/time-tracker                 hir-of/time-tracker-deploy  ← このリポジトリ
  ソースコード                          Helm チャート
  Dockerfile          ──build/push──▶  values-baas-test.yaml
  CI(GitHub Actions)                     tag: <新しいイメージタグ>
                                              │
                                              ▼ ArgoCD が監視・同期
                                          baas-test クラスタ
```

同居させると、リリースのたびに発生する「イメージタグを書き換えるだけのコミット」が
アプリの履歴を埋めてしまう。またデプロイ構成の変更（レプリカ数、リソース制限など）に
アプリの CI を走らせる必要もない。

なお **CI 基盤**（Actions Runner Controller）のマニフェストはさらに別のライフサイクルなので、
アプリ側リポジトリの `k8s/` に置いている。

## 構成

```
charts/time-tracker/
  Chart.yaml
  values.yaml                共通の既定値
  values-baas-test.yaml      baas-test 固有の値(ホスト名・イメージタグ)
  templates/
    namespace.yaml
    postgresql.yaml          StatefulSet + Headless Service + PVC(Longhorn)
    backend.yaml             Deployment + Service(+ DB 起動待ちの initContainer)
    frontend.yaml            Deployment + Service(nginx)
    ingress.yaml             /api・/api-docs → backend、/ → frontend
sealed-secrets/              暗号化済み。そのままコミットしてよい
  backend.yaml               JWT_SECRET と初期管理者(ADMIN_*)
  postgresql.yaml            DB パスワード
  harbor-pull.yaml           Harbor の imagePullSecret
secrets/                     平文 Secret の作業場所。.gitignore で除外される
```

### 単一オリジンであることが必須

Ingress が 1 つのホスト名の配下で `/api` をバックエンドへ、それ以外をフロントエンドへ振り分ける。
**別オリジンに分けてはいけない。** フロントエンドは `BASE_URL = window.location.origin` で API を
呼び（`frontend/src/api/client.ts`）、リフレッシュトークンは `SameSite=Strict; Path=/api/auth` の
Cookie で運ばれるため、オリジンが分かれると CORS と Cookie の両方が壊れて認証が成立しなくなる。

ローカル開発では vite の dev proxy が同じ役割を担っている（`frontend/vite.config.ts`）。

### backend は replicas: 1 に固定

起動時に「マイグレーション適用 → 初期管理者ブートストラップ → listen」を行う（`backend/src/main.rs`）。
複数レプリカにすると同時実行になる。スケールさせるならマイグレーションを Job へ分離すること。

## 前提となるクラスタ側の条件

| 要素 | 状態 |
|------|------|
| Ingress | Traefik（k3s 標準）。**既定証明書に `*.kubo.hexabase.io` のワイルドカードを保持**しているため、Ingress の `tls` に `secretName` は不要 |
| cert-manager | **未導入**（上記の理由で不要） |
| ストレージ | Longhorn（`longhorn` / `longhorn-retain` / `longhorn-static`）と `local-path` |
| Sealed Secrets | `kube-system/sealed-secrets-controller`（v0.36.6） |
| LimitRange | `time-tracker` namespace に設定あり。**全コンテナに requests/limits の指定が必須**（initContainer も含む） |

### 外部公開には入口 nginx への登録が要る

DNS（`*.kubo.hexabase.io` → `202.208.80.148`）の先には **nginx のリバースプロキシ**があり、
**ホスト名ごとに転送先を明示登録**する方式になっている。未登録のホスト名は
**Ingress が正常でも外部からは 502** になる（存在しないホスト名と同じ応答）。

登録に必要な情報:

| 項目 | 値 |
|------|------|
| ホスト名 | `test-time-tracker.kubo.hexabase.io` |
| 転送先 | `192.168.10.168` / `192.168.10.190` / `192.168.9.203`（Traefik の LoadBalancer IP） |
| スキーム | **HTTPS(443)** |
| NodePort | web=`31615` / websecure=`31459` |

```nginx
proxy_pass https://192.168.10.190:443;
proxy_ssl_server_name on;
proxy_ssl_name  test-time-tracker.kubo.hexabase.io;
proxy_set_header Host $host;
```

> **HTTP(80) では 404 になる。** Ingress に
> `traefik.ingress.kubernetes.io/router.entrypoints: websecure` を付けているため、Traefik は
> このルートを 443 でのみ公開する。80 番には一致するルートが存在しない。
>
> **`proxy_cookie_path` を設定してはいけない。** リフレッシュトークンの Cookie は
> `Path=/api/auth` で発行される。パスを書き換えるとブラウザが `/api/auth/refresh` へ
> Cookie を送らなくなり、「ログインはできるが 15 分後に強制ログアウトされる」という
> 初回テストでは見つからない不具合になる。

## Secret の作り方

平文の `Secret` は**コミットしない**。`kubeseal` で暗号化した SealedSecret だけをコミットする。

SealedSecret は**クラスタの秘密鍵**でしか復号できず、**namespace と名前にも紐づく**ため、
public リポジトリに置いても安全。逆に言えば、**namespace を変えると復号できなくなる**ので
封をする前に対象を確定させること。

```bash
# 1. 平文 Secret を組み立てて封をする(--dry-run なのでクラスタには作られない)
kubectl --context baas-test create secret generic time-tracker-backend \
  --namespace time-tracker \
  --from-literal=jwt-secret="$(openssl rand -base64 48)" \
  --from-literal=admin-username='admin' \
  --from-literal=admin-password='<生成したパスワード>' \
  --from-literal=admin-display-name='管理者' \
  --dry-run=client -o yaml \
| kubeseal --context baas-test --format yaml > sealed-secrets/backend.yaml

# 2. 対象クラスタの鍵で復号できることを検証する(重要。下記参照)
kubeseal --context baas-test --re-encrypt -f sealed-secrets/backend.yaml -o yaml >/dev/null \
  && echo "OK: baas-test のコントローラで復号できる"
```

> **なぜ `--re-encrypt` で検証するのか**
>
> `kubeseal` は `--context` を間違えても**エラーを出さずに別クラスタの公開鍵で暗号化する**。
> 手元では成功して見えるため気づけず、**`apply` してコントローラが復号に失敗して初めて**
> 問題が表面化する。`--re-encrypt` は対象クラスタのコントローラに復号させるので、
> 鍵の取り違えをその場で検出できる。

`JWT_SECRET` は **32 byte 以上**でないとバックエンドが起動を拒否する（`design.md` の Config）。

### 秘密の値を紛失したら

暗号文からは戻せない。**新しい値で封をし直して差し替える**。

- `jwt-secret` を変えると既存のアクセストークンが無効になる（利用者は再ログインで復帰）
- `admin-password` の変更は、初期管理者ブートストラップが **users テーブルが空のときだけ**動くため、
  すでに稼働している環境では効かない。稼働中に変えるなら API か DB を直接操作する

### 検証

```bash
# 平文が混入していないことを構造で確認する(grep では不十分)
python3 - <<'PY'
import yaml, glob
for f in sorted(glob.glob("sealed-secrets/*.yaml")):
    d = yaml.safe_load(open(f))
    enc = d.get("spec", {}).get("encryptedData", {})
    leak = d.get("spec", {}).get("template", {}).get("data")
    bad = [k for k, v in enc.items() if not str(v).startswith("Ag")]
    print(f, d.get("kind"), "NG" if (d.get("kind") != "SealedSecret" or bad or leak) else "OK")
PY
```

`Ag` 始まりは sealed-secrets の暗号エンベロープの先頭バイトで、平文の base64 では通常あり得ない。
**`grep` によるシークレット検査は「無いこと」の証明には弱い** — `encryptedData:` の下に
インデントされた行を拾って誤検知する。構造を見るか専用ツール（gitleaks 等）を使うこと。

## デプロイ

### ArgoCD（正）

ArgoCD がこのリポジトリを監視する。イメージタグはアプリ側 CI が更新 PR を出す。

**同期は手動**（`syncPolicy.automated` を設定していない）。`main` が動くと ArgoCD は
`OutOfSync` を表示するが、**適用は自分で指示する**。

```bash
argocd app get  argocd/time-tracker            # 差分の確認(どのリソースが OutOfSync か)
argocd app sync argocd/time-tracker            # 適用
argocd app sync argocd/time-tracker-secrets    # SealedSecret 側
```

検証環境をデモに使う都合上、**反映のタイミングを人が決められる**ほうが都合がよいため
（説明の途中で Pod が入れ替わらない）。自動同期にする手順は
`argocd/application.yaml` のコメントを参照。

> ArgoCD がリポジトリを見に行く間隔は **120 秒**（`argocd-cm` の `timeout.reconciliation`）。
> マージ直後に `OutOfSync` にならなくても異常ではない。急ぐなら
> `argocd app get --refresh argocd/time-tracker` で即時に確認できる。

**同期しないときはまず Git を疑う。** クラスタではなく `main` の実体を見ること。

```bash
gh api repos/hir-of/time-tracker-deploy/commits/main --jq .sha
```

`Sync Status: Synced to main (<sha>)` の `<sha>` と一致していれば ArgoCD は正常で、
「同期すべき変更が無い」だけ（PR のマージ漏れなど）。

### 手動 helm（初期構築・緊急時）

```bash
# SealedSecret を先に適用する(Pod が Secret を待つため)
kubectl --context baas-test apply -f sealed-secrets/

helm upgrade --install time-tracker charts/time-tracker \
  --kube-context baas-test \
  --namespace time-tracker \
  -f charts/time-tracker/values-baas-test.yaml \
  --set global.createNamespace=false \
  --wait --timeout 5m
```

> **`--set global.createNamespace=false` が要る理由**: namespace は `kubectl` で先に作られており
> Helm の管理下にない。Helm に作らせようとすると `invalid ownership metadata` で失敗する。
> namespace ごと新規に作る環境ではこのフラグは不要。

適用前に差分を見るなら:

```bash
diff <(helm get manifest time-tracker --kube-context baas-test -n time-tracker) \
     <(helm template time-tracker charts/time-tracker \
         -f charts/time-tracker/values-baas-test.yaml \
         --set global.createNamespace=false --namespace time-tracker)
```

## 動作確認

クラスタ内から Traefik を直接叩く（入口 nginx の登録状況に左右されずに確認できる）。

```bash
kubectl --context baas-test run probe -n time-tracker --rm -it \
  --image=curlimages/curl:8.11.1 --restart=Never -- sh -c '
    H=test-time-tracker.kubo.hexabase.io
    IP=$(getent hosts traefik.kube-system.svc.cluster.local | awk "{print \$1}")
    for p in / /api-docs/openapi.json /api/projects; do
      echo "$p -> $(curl -sk -o /dev/null -w "%{http_code}" --resolve "$H:443:$IP" "https://$H$p")"
    done'
```

期待値: `/` = 200（SPA）、`/api-docs/openapi.json` = 200（バックエンド）、`/api/projects` = **401**（未認証を正しく拒否）。

**HTTP(80) で叩くと全て 404 になる**（websecure 限定のため）。これは異常ではない。

外部から確認するなら、認証の一巡まで通すこと:

```bash
H=https://test-time-tracker.kubo.hexabase.io
TOKEN=$(curl -s -c /tmp/c.txt -X POST "$H/api/auth/login" -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<パスワード>"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')
curl -s -o /dev/null -w 'projects=%{http_code}\n' -H "Authorization: Bearer $TOKEN" "$H/api/projects"
curl -s -o /dev/null -w 'refresh=%{http_code}\n' -b /tmp/c.txt -X POST "$H/api/auth/refresh"
```

**リフレッシュまで確認する**のが重要。リバースプロキシ越しで最も壊れやすいのが Cookie の扱いで、
ログインだけの確認では通ってしまう。

## トラブルシュート

| 症状 | 原因と対処 |
|------|------------|
| 外部から **502**（`nginx` の応答） | 入口 nginx にホスト名が未登録。Ingress 側は正常。存在しないホスト名と同じ応答なので区別がつかない |
| **404**（Traefik の応答） | HTTP(80) で叩いている。443 を使う。または Ingress のホスト名が実際のアクセス先と食い違っている |
| backend が `Init:0/1` のまま | PostgreSQL が起動していない。`kubectl --context baas-test -n time-tracker logs <pod> -c wait-for-postgresql` で待機理由を確認 |
| backend が `CrashLoopBackOff` | Secret 不足（`JWT_SECRET` が 32 byte 未満など）か DB 接続失敗。`kubectl logs` を見る |
| Pod が `ImagePullBackOff` | `harbor-pull` の SealedSecret が未適用か、Harbor のロボットアカウントの権限不足。**push だけでは足りず pull 権限も要る**（`docker push` は送信前に `HEAD .../blobs/...` で既存レイヤーを確認し、Harbor はこれを pull 権限として判定する） |
| Pod が `Pending` で `failed quota` 系 | LimitRange により requests/limits が必須。initContainer にも指定が要る |
| ログインは通るが数分後にログアウトされる | 入口 nginx が Cookie のパスを書き換えている。`proxy_cookie_path` を外す |

## 関連

- アプリ本体: [hir-of/time-tracker](https://github.com/hir-of/time-tracker)
- CI ランナー（Actions Runner Controller）の構成: アプリ側リポジトリの `.github/RUNNER.md`
- 仕様（要件・設計）: アプリ側リポジトリの `.kiro/specs/time-tracker/`
