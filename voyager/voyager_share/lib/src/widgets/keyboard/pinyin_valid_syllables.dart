/// All valid pinyin syllables, sorted by length descending for greedy matching.
const List<String> pinyinValidSyllables = [
  // 6-letter syllables
  'zhuang', 'chuang', 'shuang',
  // 5-letter syllables
  'zhong', 'zhang', 'zheng', 'zhuai', 'zhuan', 'chang', 'cheng', 'chong',
  'chuai', 'chuan', 'guang', 'huang', 'jiang', 'jiong', 'kuang', 'liang',
  'niang', 'qiang', 'qiong', 'shang', 'sheng', 'shuai', 'shuan', 'xiang',
  'xiong',
  // 4-letter syllables
  'bang', 'beng', 'bian', 'biao', 'bing', 'cang', 'ceng', 'chai', 'chan',
  'chao', 'chen', 'chui', 'chun', 'chuo', 'cong', 'cuan', 'dang', 'deng',
  'dian', 'diao', 'ding', 'dong', 'duan', 'fang', 'feng', 'gang', 'geng',
  'gong', 'guai', 'guan', 'gong', 'hang', 'heng', 'hong', 'huai', 'huan',
  'jian', 'jiao', 'jing', 'juan', 'kang', 'keng', 'kong', 'kuai', 'kuan',
  'lang', 'leng', 'lian', 'liao', 'ling', 'long', 'luan', 'luan', 'mang',
  'meng', 'mian', 'miao', 'ming', 'nang', 'neng', 'nian', 'niao', 'ning',
  'nong', 'nuan', 'pang', 'peng', 'pian', 'piao', 'ping', 'qian', 'qiao',
  'qing', 'quan', 'rang', 'reng', 'rong', 'ruan', 'sang', 'seng', 'shan',
  'shao', 'shei', 'shen', 'shou', 'shua', 'shui', 'shun', 'shuo', 'song',
  'suan', 'tang', 'teng', 'tian', 'tiao', 'ting', 'tong', 'tuan', 'wang',
  'weng', 'xian', 'xiao', 'xing', 'xuan', 'yang', 'ying', 'yong', 'yuan',
  'zang', 'zeng', 'zhai', 'zhan', 'zhao', 'zhei', 'zhen', 'zhou', 'zhua',
  'zhui', 'zhun', 'zhuo', 'zong', 'zuan', 'chou', 'ghou',
  // 3-letter syllables
  'ang', 'bai', 'ban', 'bao', 'bei', 'ben', 'bin', 'bie', 'bao',
  'cai', 'can', 'cao', 'che', 'chi', 'chu', 'cou', 'cui', 'cun', 'cuo',
  'dai', 'dan', 'dao', 'dei', 'den', 'dia', 'die', 'diu', 'dou', 'dui',
  'dun', 'duo', 'fan', 'fei', 'fen', 'fou', 'gai', 'gan', 'gao', 'gei',
  'gen', 'gou', 'gua', 'gui', 'gun', 'guo', 'hai', 'han', 'hao', 'hei',
  'hen', 'hou', 'hua', 'hui', 'hun', 'huo', 'jia', 'jie', 'jin', 'jiu',
  'jun', 'kai', 'kan', 'kao', 'ken', 'kou', 'kua', 'kui', 'kun', 'kuo',
  'lai', 'lan', 'lao', 'lei', 'lia', 'lie', 'lin', 'liu', 'lou',
  'lun', 'luo', 'mai', 'man', 'mao', 'mei', 'men', 'mie', 'min', 'miu',
  'mou', 'nai', 'nan', 'nao', 'nei', 'nen', 'nie', 'nin', 'niu', 'nou',
  'nuo', 'nve', 'pai', 'pan', 'pao', 'pei', 'pen', 'pie', 'pin', 'pou',
  'qie', 'qin', 'qiu', 'que', 'qun', 'ran', 'rao', 'ren', 'rou', 'rui',
  'run', 'ruo', 'sai', 'san', 'sao', 'sen', 'sha', 'she', 'shi', 'shu',
  'sou', 'sui', 'sun', 'suo', 'tai', 'tan', 'tao', 'tie', 'tou', 'tui',
  'tun', 'tuo', 'wai', 'wan', 'wei', 'wen', 'xia', 'xie', 'xin', 'xiu',
  'xue', 'xun', 'yao', 'yin', 'you', 'yue', 'yun', 'zai', 'zan', 'zao',
  'zei', 'zen', 'zha', 'zhe', 'zhi', 'zhu', 'zou', 'zui', 'zun', 'zuo',
  'eng', 'lve',
  // 2-letter syllables
  'ai', 'an', 'ao', 'ba', 'bi', 'bo', 'bu', 'ca', 'ce', 'ci', 'cu',
  'da', 'de', 'di', 'du', 'ei', 'en', 'er', 'fa', 'fo', 'fu', 'ga',
  'ge', 'gu', 'ha', 'he', 'hu', 'ji', 'ju', 'ka', 'ke', 'ku', 'la',
  'le', 'li', 'lo', 'lu', 'lv', 'ma', 'me', 'mi', 'mo', 'mu', 'na',
  'ne', 'ni', 'nu', 'nv', 'ou', 'pa', 'pi', 'po', 'pu', 'qi', 'qu',
  're', 'ri', 'ru', 'sa', 'se', 'si', 'su', 'ta', 'te', 'ti', 'tu',
  'wa', 'wo', 'wu', 'xi', 'xu', 'ya', 'ye', 'yi', 'yo', 'yu', 'za',
  'ze', 'zi', 'zu',
  // 1-letter syllables
  'a', 'e', 'o',
];

/// Set of valid syllables for quick lookup.
final Set<String> pinyinSyllableSet = Set.unmodifiable(
  pinyinValidSyllables.toSet(),
);
