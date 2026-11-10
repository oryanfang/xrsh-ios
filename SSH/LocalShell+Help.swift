import Foundation

/// 小命令行 help 的日语、俄语版本（中文和英文在 LocalShell.helpText 里）
extension LocalShell {
    static let japaneseHelp = """
    ローカルターミナル：アプリのサンドボックス内で動く小さなシェル（ファイルはアプリ専用のフォルダに置かれます）

    ファイル   ls  cd  pwd  cat  mkdir  rm  cp  mv  touch  head  tail  wc  grep
    情報       echo  date  whoami  hostname  uname  ifconfig  history  clear
    システム   df  free  uptime  ps（iOS ではこのアプリしか見えません）
    ネット     ping  curl  scan（ローカルネットワークをスキャン）  devices（デバイス一覧）  ssh [ユーザー@]ホスト [-p ポート]
    終了       exit

    パイプ |、リダイレクト > >>、引用符、Tab 補完、↑↓ で履歴に対応しています。
    例：ls -l | grep txt      echo hi > a.txt      curl -O https://example.com/a.zip
    実行中は Ctrl+C で中断できます（ping や curl のダウンロード中など）

    """

    static let russianHelp = """
    Локальный терминал: небольшая оболочка внутри песочницы приложения (файлы лежат в собственной папке приложения)

    Файлы      ls  cd  pwd  cat  mkdir  rm  cp  mv  touch  head  tail  wc  grep
    Сведения   echo  date  whoami  hostname  uname  ifconfig  history  clear
    Система    df  free  uptime  ps (iOS показывает только это приложение)
    Сеть       ping  curl  scan (сканировать локальную сеть)  devices (список устройств)  ssh [пользователь@]хост [-p порт]
    Выход      exit

    Поддерживаются конвейеры |, перенаправления > >>, кавычки, дополнение по Tab и история по ↑↓.
    Примеры: ls -l | grep txt      echo hi > a.txt      curl -O https://example.com/a.zip
    Ctrl+C прерывает выполняемую команду (ping, загрузку через curl)

    """
}
