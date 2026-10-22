import 'package:flutter_test/flutter_test.dart';
import 'package:ntako_timer/core/database/app_database.dart';
import 'package:ntako_timer/features/voice/timer_commands.dart';

Task task(String id, String title,
        {String? category, bool completed = false, bool deleted = false}) =>
    Task(
      id: id,
      categoryId: category,
      title: title,
      type: 'tracker',
      isCompleted: completed,
      createdAt: 0,
      updatedAt: 0,
      deletedAt: deleted ? 1 : null,
      isSynced: true,
    );

String? describe(TimerCommand? c) =>
    c == null ? null : '${c.action.name}${c.task == null ? '' : ':${c.task}'}';

void main() {
  test('links', () {
    TimerCommand? link(String s) => TimerCommand.fromUri(Uri.parse(s));
    expect(describe(link('ntako://timer/start')), 'start');
    expect(describe(link('ntako://timer/start?task=Odoo%20Amazon%20Sync')), 'start:Odoo Amazon Sync');
    expect(describe(link('ntako://timer/start?task=%20')), 'start', reason: 'blank task = selected task');
    expect(describe(link('ntako://timer/pause')), 'pause');
    expect(describe(link('ntako://timer/resume')), 'resume');
    expect(describe(link('ntako://timer/stop')), 'stop');
    expect(link('ntako://timer/explode'), isNull);
    expect(link('ntako://other/start'), isNull);
    expect(link('https://www.ntako.com/timer/start'), isNull);
  });

  test('spoken Italian', () {
    String? say(String s) => describe(TimerCommand.fromSpeech(s));
    expect(say('Avvia Arundo'), 'start:arundo');
    expect(say('avvia il timer su Odoo Amazon Sync'), 'start:odoo amazon sync');
    expect(say('inizia il task sviluppo odoo'), 'start:sviluppo odoo');
    expect(say('avvia la sessione per la riunione'), 'start:riunione');
    expect(say('avvia'), 'start');
    expect(say('avvia il timer'), 'start');
    expect(say('metti in pausa'), 'pause');
    expect(say('pausa'), 'pause');
    expect(say('riprendi'), 'resume');
    expect(say('continua il lavoro'), 'resume');
    expect(say('ferma il timer'), 'stop');
    expect(say('Stop.'), 'stop');
    expect(say('che tempo fa domani'), isNull);
    expect(say('avviare'), isNull, reason: 'whole words only');
  });

  test('task matching', () {
    final tasks = [
      task('1', 'Odoo Amazon Sync'),
      task('2', 'Odoo Prestashop Sync'),
      task('3', 'Sviluppo Odoo'),
      task('4', 'Caffè e riunione'),
      task('5', 'Vecchio progetto', completed: true),
      task('6', 'Arundo', deleted: true),
    ];
    String? id(String q) => matchTask(tasks, q).task?.id;
    expect(id('odoo amazon sync'), '1', reason: 'exact');
    expect(id('Odoo Amazon'), '1', reason: 'prefix');
    expect(id('prestashop'), '2', reason: 'contained');
    expect(id('sync amazon'), '1', reason: 'all words, any order');
    expect(id('caffe'), '4', reason: 'no accents needed');
    expect(id('sviluppo odoo'), '3');
    expect(id('vecchio progetto'), isNull, reason: 'completed tasks are not offered');
    expect(id('arundo'), isNull, reason: 'deleted tasks are not offered');
    expect(id('qualcosa'), isNull);

    final odoo = matchTask(tasks, 'odoo');
    expect(odoo.task, isNull);
    expect(odoo.ambiguous.map((t) => t.id), ['1', '2'], reason: 'two names start with it');
  });

  test('partial names only from the start of a word', () {
    final tasks = [task('1', 'Contest clienti'), task('2', 'Sviluppo Odoo')];
    String? id(String q) => matchTask(tasks, q).task?.id;
    expect(id('test'), isNull, reason: '"test" is inside "Contest", not a word start');
    expect(id('svil'), '2');
    expect(id('odo'), '2', reason: 'start of the second word');
    expect(id('clienti contest'), '1');
  });

  test('same title in different categories', () {
    const cats = {'a': 'Arundo', 'o': 'Odoo'};
    final tasks = [
      task('1', 'Sviluppo', category: 'a'),
      task('2', 'Sviluppo', category: 'o'),
      task('3', 'Riunione'),
    ];
    TaskMatch m(String q) => matchTask(tasks, q, categoryNames: cats);
    expect(m('sviluppo').task, isNull);
    expect(m('sviluppo').ambiguous.map((t) => t.id), ['1', '2']);
    expect(m('sviluppo arundo').task?.id, '1', reason: 'title + category');
    expect(m('sviluppo di odoo').task?.id, '2', reason: 'link words are ignored');
    expect(m('arundo sviluppo').task?.id, '1', reason: 'any order');
    expect(m('riunione').task?.id, '3');
    expect(taskLabel(tasks[0], cats), 'Sviluppo (Arundo)');
    expect(taskLabel(tasks[2], cats), 'Riunione');
  });
}
