// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/pages/chat_search/chat_search_view.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ChatSearchPage extends StatefulWidget {
  final String roomId;
  const ChatSearchPage({required this.roomId, super.key});

  @override
  ChatSearchController createState() => ChatSearchController();
}

class ChatSearchController extends State<ChatSearchPage>
    with SingleTickerProviderStateMixin {
  Room? get room => Matrix.of(context).client.getRoomById(widget.roomId);

  final TextEditingController searchController = TextEditingController();
  late final TabController tabController;

  final List<Event> messages = [];
  final List<Event> images = [];
  final List<Event> files = [];
  String? messagesNextBatch, imagesNextBatch, filesNextBatch;
  bool messagesEndReached = false;
  bool imagesEndReached = false;
  bool filesEndReached = false;
  bool isLoading = false;
  DateTime? searchedUntil;

  // A new query starts a new generation: answers of an older query (and
  // their next batch) never land in the newer list.
  int _generation = 0;
  int _inFlight = 0;

  void restartSearch() {
    _generation++;
    setState(() {
      messages.clear();
      images.clear();
      files.clear();
      messagesNextBatch = imagesNextBatch = filesNextBatch = searchedUntil =
          null;
      messagesEndReached = imagesEndReached = filesEndReached = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      startSearch();
    });
  }

  /// Searches the current tab; a failed request is explained with "Try
  /// again" instead of leaving the page loading forever.
  Future<void> startSearch() async {
    final generation = _generation;
    try {
      await _search();
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      setState(() => isLoading = _inFlight > 0);
      await ErrorReporter.action(
        context,
        action: ErrorAction.load,
        onRetry: startSearch,
      ).onErrorCallback(error, stack);
    }
  }

  Future<void> _search() async {
    final generation = _generation;
    final tab = tabController.index;
    final query = searchController.text.trim();
    if (tab == 0 && query.isEmpty) return;
    if (tab < 0 || tab > 2) return;
    setState(() => isLoading = true);
    _inFlight++;
    final ({List<Event> events, String? nextBatch, DateTime? searchedUntil})
    result;
    try {
      result = await switch (tab) {
        0 => room!.searchEvents(
          searchTerm: query,
          nextBatch: messagesNextBatch,
        ),
        1 => room!.searchEvents(
          searchFunc: (event) => {
            MessageTypes.Image,
            MessageTypes.Video,
          }.contains(event.messageType),
          nextBatch: imagesNextBatch,
        ),
        _ => room!.searchEvents(
          searchFunc: (event) =>
              event.messageType == MessageTypes.File ||
              (event.messageType == MessageTypes.Audio &&
                  !event.content.containsKey('org.matrix.msc3245.voice')),
          nextBatch: filesNextBatch,
        ),
      };
    } finally {
      _inFlight--;
    }
    // A newer query (or a closed page) owns the lists now.
    if (!mounted || generation != _generation) return;
    setState(() {
      isLoading = _inFlight > 0;
      switch (tab) {
        case 0:
          messages.addAll(result.events);
          messagesNextBatch = result.nextBatch;
          messagesEndReached = result.nextBatch == null;
        case 1:
          images.addAll(result.events);
          imagesNextBatch = result.nextBatch;
          imagesEndReached = result.nextBatch == null;
        default:
          files.addAll(result.events);
          filesNextBatch = result.nextBatch;
          filesEndReached = result.nextBatch == null;
      }
      searchedUntil = result.searchedUntil;
    });
  }

  void _onTabChanged() {
    // A tap notifies twice (animation start and end); search once.
    if (tabController.indexIsChanging) return;
    switch (tabController.index) {
      case 1:
        // Media and files load their first page once; the list's footer
        // loads more.
        if (images.isEmpty && !imagesEndReached) startSearch();
        break;
      case 2:
        if (files.isEmpty && !filesEndReached) startSearch();
        break;
      case 0:
      default:
        restartSearch();
        break;
    }
  }

  @override
  void initState() {
    super.initState();
    tabController = TabController(initialIndex: 0, length: 3, vsync: this);
    tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    tabController.removeListener(_onTabChanged);
    searchController.dispose();
    tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChatSearchView(this);
}
